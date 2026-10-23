#!/usr/bin/env bash
# Installs nodiclaude's skills, agents, hooks and rules into $HOME/.claude.
# Safe to run repeatedly: it does not duplicate entries and does not rewrite what has not changed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
MANIFEST="$CLAUDE_DIR/.nodiclaude-manifest"
BACKUP_DIR="$CLAUDE_DIR/.nodiclaude-backup/$(date +%Y%m%d-%H%M%S)"

tmp=""
newlist=""
trap 'rm -f "${tmp:-}" "${newlist:-}"' EXIT

log() { echo "[nodiclaude] $*"; }

# --- Commit identity ----------------------------------------------------------------
# Resolved BEFORE touching anything. Order:
#   1. NODICLAUDE_GIT_NAME and NODICLAUDE_GIT_EMAIL, if both are set (cloud).
#   2. git config --global user.name and user.email, if both have a value (local).
#   3. Otherwise, error and exit without changing anything.
ID_SRC=""
ID_NAME=""
ID_EMAIL=""
if [ -n "${NODICLAUDE_GIT_NAME:-}" ] && [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  ID_SRC="env"
  ID_NAME="$NODICLAUDE_GIT_NAME"
  ID_EMAIL="$NODICLAUDE_GIT_EMAIL"
elif [ -n "${NODICLAUDE_GIT_NAME:-}" ] || [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  echo "[nodiclaude] ERROR: only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set." >&2
  echo "             Set both or neither. Nothing has been changed." >&2
  exit 1
else
  g_name="$(git config --global user.name 2>/dev/null || true)"
  g_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$g_name" ] && [ -n "$g_email" ]; then
    ID_SRC="global"
    ID_NAME="$g_name"
    ID_EMAIL="$g_email"
  else
    echo "[nodiclaude] ERROR: could not determine Claude's commit identity." >&2
    echo "             Set NODICLAUDE_GIT_NAME and NODICLAUDE_GIT_EMAIL (environments without a gitconfig, e.g. cloud)" >&2
    echo "             or configure 'git config --global user.name' and 'git config --global user.email' (local)." >&2
    echo "             Nothing has been changed." >&2
    exit 1
  fi
fi

mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/agents" "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/rules"

# --- jq ----------------------------------------------------------------------
# Use the existing one or try to install it.
try_run() {
  local out
  out="$("$@" 2>&1)" || { log "WARNING: '$*' failed: $(printf '%s\n' "$out" | tail -n 1)"; return 1; }
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log "jq not found; trying to install it..."
  local sudo=()
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then sudo=(sudo -n); fi
  if command -v apt-get >/dev/null 2>&1; then
    try_run ${sudo[@]+"${sudo[@]}"} apt-get install -y jq ||
      { try_run ${sudo[@]+"${sudo[@]}"} apt-get update && try_run ${sudo[@]+"${sudo[@]}"} apt-get install -y jq; } || true
  elif command -v brew >/dev/null 2>&1; then
    try_run brew install jq || true
  elif command -v apk >/dev/null 2>&1; then
    try_run ${sudo[@]+"${sudo[@]}"} apk add jq || true
  fi
  command -v jq >/dev/null 2>&1
}

# Applies a jq filter to settings.json without aborting on failure. Usage: jq_apply <description> <jq args...>
# The result is written with `cat >` to preserve symlinks and permissions.
jq_apply() {
  local what="$1"
  shift
  tmp="$(mktemp "$CLAUDE_DIR/.nodiclaude-settings.XXXXXX")"
  if jq "$@" > "$tmp" 2>/dev/null; then
    # Only written if the content changes (semantic comparison): avoids reformatting.
    if [ "$(jq -S . "$tmp")" != "$(jq -S . "$SETTINGS")" ]; then
      cat "$tmp" > "$SETTINGS"
      log "settings.json: $what"
    fi
  else
    log "WARNING: could not update settings.json ($what): invalid JSON or unexpected structure; leaving it untouched."
  fi
  rm -f "$tmp"
  tmp=""
}

# --- Repo files ---------------------------------------------------------------------
newlist="$(mktemp "$CLAUDE_DIR/.nodiclaude-list.XXXXXX")"
for top in skills agents hooks rules; do
  [ -d "$REPO_DIR/$top" ] || continue
  (cd "$REPO_DIR" && find "$top" -type f ! -name .DS_Store) | LC_ALL=C sort >> "$newlist"
done

copied=0
newmanifest=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$REPO_DIR/$rel"
  dst="$CLAUDE_DIR/$rel"
  if [ -L "$dst" ]; then
    log "WARNING: $dst is a symlink; skipping."
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ]; then
    if ! cmp -s "$src" "$dst"; then
      mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
      cp -p "$dst" "$BACKUP_DIR/$rel"
      log "backup: $dst -> $BACKUP_DIR/$rel"
      cp -f "$src" "$dst"
      log "replaced: $dst"
      copied=$((copied + 1))
    fi
  else
    cp -f "$src" "$dst"
    copied=$((copied + 1))
  fi
  case "$rel" in hooks/*) chmod +x "$dst" ;; esac
  newmanifest="${newmanifest}${rel}"$'\n'
done < "$newlist"
log "skills, agents, hooks and rules up to date in $CLAUDE_DIR ($copied files copied)"

# --- Files removed from the repo ----------------------------------------------------
removed_hooks=()
if [ -f "$MANIFEST" ]; then
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      *..* | /*) continue ;;
      skills/* | agents/* | hooks/* | rules/*) ;;
      *) continue ;;
    esac
    printf '%s' "$newmanifest" | grep -Fxq -- "$rel" && continue
    dst="$CLAUDE_DIR/$rel"
    if [ -L "$dst" ]; then
      log "WARNING: $dst is a symlink; not removing."
      continue
    fi
    # Regular files only; directories are left alone.
    if [ -d "$dst" ]; then continue; fi
    if [ -f "$dst" ]; then
      if rm -f "$dst"; then
        log "removed (no longer in the repo): $dst"
      else
        log "WARNING: could not remove $dst"
      fi
    fi
    case "$rel" in hooks/*) removed_hooks[${#removed_hooks[@]}]="${rel#hooks/}" ;; esac
    # Prune empty directories under skills/.
    case "$rel" in
      skills/*)
        d="$(dirname "$dst")"
        while [ "$d" != "$CLAUDE_DIR/skills" ] && [ "$d" != "$CLAUDE_DIR" ] && rmdir "$d" 2>/dev/null; do
          d="$(dirname "$d")"
        done
        ;;
    esac
  done < "$MANIFEST"
fi
printf '%s' "$newmanifest" > "$MANIFEST"

# --- settings.json ------------------------------------------------------------------
if [ ! -s "$SETTINGS" ]; then
  cat "$REPO_DIR/settings.json" > "$SETTINGS"
  log "settings.json created"
elif ensure_jq; then
  for h in ${removed_hooks[@]+"${removed_hooks[@]}"}; do
    jq_apply "removed hook $h" --arg name "$h" '
      if (.hooks | type) == "object" then
        .hooks |= with_entries(
          if (.value | type) == "array" then
            .value |= ([ .[] | .hooks |= (if type == "array" then map(select((.command // "" | endswith("/hooks/" + $name)) | not)) else . end) ]
                       | map(select((.hooks | type) != "array" or (.hooks | length) > 0)))
          else . end)
      else . end' "$SETTINGS"
  done
  # Hook entries are replaced by command (a matcher change is applied without
  # duplicating); for all other keys the existing value wins.
  jq_apply "merged" -s '
    .[0] as $new | .[1] as $old
    | (($new | del(.hooks)) * $old) as $base
    | reduce (($new.hooks // {}) | to_entries[]) as $ev ($base;
        ($ev.value | [ .[] | .hooks[]? | .command ]) as $cmds
        | .hooks[$ev.key] = (
            [ (.hooks[$ev.key] // [])[]
              | select(([ .hooks[]? | .command ] | any(. as $c | $cmds | index($c))) | not) ]
            + $ev.value))
  ' "$REPO_DIR/settings.json" "$SETTINGS"
else
  log "WARNING: no jq; existing settings.json left unmodified (merge it by hand)."
fi

# --- Global git identity ------------------------------------------------------------
if [ "$ID_SRC" = "global" ]; then
  # Local: never writes to any gitconfig.
  log "commit identity (git config --global): '$ID_NAME' <$ID_EMAIL>"
else
  # Cloud: only the missing keys are written; an existing one is never overwritten.
  log "commit identity (NODICLAUDE_GIT_*): '$ID_NAME' <$ID_EMAIL>"
  for key in name email; do
    if [ "$key" = "name" ]; then want="$ID_NAME"; var="NODICLAUDE_GIT_NAME"; else want="$ID_EMAIL"; var="NODICLAUDE_GIT_EMAIL"; fi
    cur="$(git config --global "user.$key" 2>/dev/null || true)"
    if [ -z "$cur" ]; then
      if git config --global "user.$key" "$want"; then
        log "git config --global user.$key written: '$want'"
      else
        log "WARNING: could not write git config --global user.$key"
      fi
    elif [ "$cur" != "$want" ]; then
      log "WARNING: git config --global user.$key is '$cur' and ${var} requires '$want'; not overwriting. The hook will block commits until they match."
    fi
  done
fi

log "installation complete"
