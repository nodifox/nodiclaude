#!/usr/bin/env bash
# Tells the user when the installed nodiclaude is older than main of its remote.
# It only notifies; it never updates anything.
#
# Usage: check-update.sh session-start | prompt
#   session-start: always asks the remote (bounded to about 4 seconds) and notifies
#                  whenever the installed version is outdated.
#   prompt:        reads a local cache only; refreshes it in the background at most
#                  once per hour; notifies once per new remote version.
#
# On ANY problem it prints nothing and exits 0. Bash 3.2 compatible, no jq.

CLAUDE_DIR="$HOME/.claude"
VERSION_FILE="$CLAUDE_DIR/.nodiclaude-version"
CACHE_FILE="$CLAUDE_DIR/.nodiclaude-update-cache"
MAX_AGE=3600
LOOKUP_TICKS=40 # x 0.1s = 4 seconds

HASH_RE='^[0-9a-f]{40,64}$'

cache_get() { # cache_get <key>
  [ -f "$CACHE_FILE" ] || return 0
  grep -m1 "^$1=" "$CACHE_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r\n'
  return 0
}

# write_cache <checked> <remote> <notified>; atomic: temp file in the same dir + mv
write_cache() {
  local t
  t="$(mktemp "$CLAUDE_DIR/.nodiclaude-cache.XXXXXX" 2>/dev/null)" || return 0
  if printf 'checked=%s\nremote=%s\nnotified=%s\n' "$1" "$2" "$3" > "$t" 2>/dev/null; then
    mv -f "$t" "$CACHE_FILE" 2>/dev/null || rm -f "$t"
  else
    rm -f "$t"
  fi
  return 0
}

# lookup <url>: prints the hash of refs/heads/main, or nothing on any failure or timeout.
lookup() {
  local out pid i hash
  command -v git >/dev/null 2>&1 || return 0
  out="$(mktemp "${TMPDIR:-/tmp}/nodiclaude-lookup.XXXXXX" 2>/dev/null)" || return 0
  # BatchMode: ssh must not prompt on /dev/tty; a user-set GIT_SSH_COMMAND is kept.
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" GIT_TERMINAL_PROMPT=0 git ls-remote -- "$1" refs/heads/main > "$out" 2>/dev/null < /dev/null &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$LOOKUP_TICKS" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$out"
    return 0
  fi
  wait "$pid" 2>/dev/null
  if [ $? -eq 0 ]; then
    hash="$(head -n 1 "$out" 2>/dev/null | cut -f1 | tr -d ' \r\n')"
    if printf '%s' "$hash" | grep -Eq "$HASH_RE"; then printf '%s' "$hash"; fi
  fi
  rm -f "$out"
  return 0
}

notice() { # notice <installed> <remote>
  local a="${1:0:7}" b="${2:0:7}"
  printf 'nodiclaude is outdated (installed %s, latest %s).\n' "$a" "$b"
  printf 'Local: git pull && ./install.sh\n'
  printf 'Cloud: in the environment setup script change "# rev: ..." to "# rev: %s" and start a new session.\n' "$b"
}

# Refresh the cache with a fresh lookup (used in the background by `prompt`).
refresh() { # refresh <url>
  local r
  r="$(lookup "$1")"
  [ -n "$r" ] || return 0
  write_cache "$(date +%s)" "$r" "$(cache_get notified)"
  return 0
}

main() {
  local mode="$1" installed url now checked remote notified r changed need
  [ -f "$VERSION_FILE" ] || return 0
  installed="$(sed -n 1p "$VERSION_FILE" 2>/dev/null | tr -d '\r\n ')"
  url="$(sed -n 2p "$VERSION_FILE" 2>/dev/null | tr -d '\r\n')"
  [ -n "$url" ] || return 0
  case "$url" in -*) return 0 ;; esac # would be parsed as a git option
  printf '%s' "$installed" | grep -Eq "$HASH_RE" || return 0
  now="$(date +%s 2>/dev/null)"
  printf '%s' "$now" | grep -Eq '^[0-9]+$' || return 0

  case "$mode" in
    session-start)
      r="$(lookup "$url")"
      [ -n "$r" ] || return 0
      notified="$(cache_get notified)"
      if [ "$r" != "$installed" ]; then
        notice "$installed" "$r"
        notified="$r"
      fi
      write_cache "$now" "$r" "$notified"
      ;;
    prompt)
      checked="$(cache_get checked)"
      remote="$(cache_get remote)"
      notified="$(cache_get notified)"
      printf '%s' "$checked" | grep -Eq '^[0-9]+$' || checked=""
      printf '%s' "$remote" | grep -Eq "$HASH_RE" || remote=""
      printf '%s' "$notified" | grep -Eq "$HASH_RE" || notified=""
      changed=0
      need=0
      if [ -z "$checked" ] || [ $((now - checked)) -gt "$MAX_AGE" ] || [ "$checked" -gt "$now" ]; then
        need=1
      fi
      if [ -n "$remote" ] && [ "$remote" != "$installed" ] && [ "$remote" != "$notified" ]; then
        notice "$installed" "$remote"
        notified="$remote"
        changed=1
      fi
      if [ "$need" -eq 1 ]; then
        # Marking the check as done before launching also throttles failing lookups.
        checked="$now"
        changed=1
      fi
      [ "$changed" -eq 1 ] && write_cache "$checked" "$remote" "$notified"
      if [ "$need" -eq 1 ]; then
        # Detached: no inherited pipes, so Claude Code does not wait for it.
        ( refresh "$url" ) < /dev/null > /dev/null 2>&1 &
      fi
      ;;
  esac
  return 0
}

main "${1:-}" 2>/dev/null
exit 0
