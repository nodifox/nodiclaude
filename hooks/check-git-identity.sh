#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks `git commit` if the effective identity
# (author and committer) does not match the expected identity, which is resolved as follows:
#   1. NODICLAUDE_GIT_NAME and NODICLAUDE_GIT_EMAIL, if both are set (cloud).
#   2. otherwise, `git config --global user.name` and `user.email`, if both have a value (local).
#   3. otherwise, warn and allow (exit 0). With only one of the two variables, it also warns and allows.
#
# It is a "best effort" safeguard: it does not detect aliases (e.g. `git ci`), dynamically
# built commands (variables, eval, scripts) or commits made outside the Bash tool.
# On any unexpected failure (missing jq/git, invalid input, directory that is not a repo,
# expected identity not resolvable) it warns on stderr and allows the command (exit 0).
# It only blocks (exit 2) on a real mismatch.
#
# Input: JSON on stdin with tool_input.command and cwd.
# Bash 3.2 compatible (macOS): no mapfile, associative arrays or ${var,,}.

warn() { echo "check-git-identity: warning: $*" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq not available; git identity not verified."; exit 0; }

input="$(cat)" || { warn "could not read the hook input."; exit 0; }
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" ||
  { warn "invalid hook input."; exit 0; }
[ -n "$command_str" ] || exit 0

# --- `git commit` detection ---------------------------------------------------
# Prefix: start, `/`, quotes, backtick, `{`, `;&|(` or whitespace. Options before
# the subcommand: `-x`/`--long` with an optional value (quoted or unquoted).
sq="'"
bq='`'
pre="(^|[/\"${sq}${bq}{;&|(]|[[:space:]])"
# Value: a mix of quoted segments, \-escaped characters and plain text.
optval="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|\\\\.|[^-[:space:];&|\"${sq}${bq})\\\\])(\"[^\"]*\"|${sq}[^${sq}]*${sq}|\\\\.|[^[:space:];&|\"${sq}${bq})\\\\])*"
opts="([[:space:]]+-[-A-Za-z0-9_.]+([[:space:]]+${optval})?)*"
commit_re="${pre}git${opts}[[:space:]]+commit([[:space:];&|)\"${sq}${bq}}]|\$)"

[[ $command_str =~ $commit_re ]] || exit 0

# Splits a string into words (removing quotes) up to the first unquoted command
# separator. Result in the TOK array.
tokenize() {
  TOK=()
  local s="$1" i=0 n=${#1} c cur="" inw=0 q=""
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    i=$((i + 1))
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then
        q=""
      elif [ "$c" = "\\" ] && [ "$q" = '"' ] && [ "$i" -lt "$n" ]; then
        cur="${cur}${s:$i:1}"
        i=$((i + 1))
      else
        cur="${cur}${c}"
      fi
      continue
    fi
    case "$c" in
      '"' | "'") q="$c"; inw=1 ;;
      '\')
        if [ "$i" -lt "$n" ]; then cur="${cur}${s:$i:1}"; i=$((i + 1)); inw=1; fi
        ;;
      ' ' | $'\t')
        if [ "$inw" -eq 1 ]; then TOK[${#TOK[@]}]="$cur"; cur=""; inw=0; fi
        ;;
      ';' | '&' | '|' | ')' | '`' | $'\n') break ;;
      *) cur="${cur}${c}"; inw=1 ;;
    esac
  done
  if [ "$inw" -eq 1 ]; then TOK[${#TOK[@]}]="$cur"; fi
}

# Resolves $2 relative to $1 (supports ~ and absolute paths).
resolve_dir() {
  local base="$1" d="$2"
  d="$(printf '%s' "$d" | sed 's/\\\(.\)/\1/g')"
  case "$d" in
    "~") d="$HOME" ;;
    "~/"*) d="$HOME/${d#"~/"}" ;;
  esac
  case "$d" in
    /*) printf '%s' "$d" ;;
    *) printf '%s/%s' "$base" "$d" ;;
  esac
}

# Evaluates one `git commit`: uses before, m and after. Returns 0 (ok/not verifiable) or 2 (block).
check_one() {
# --- Target repo -----------------------------------------------------------------
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="."
repo="$cwd"

# `cd <dir> &&` / `cd <dir> ;` before git (the last one is used).
cd_re="^(.*[;&|(${bq}[:space:]])?cd[[:space:]]+(\"[^\"]*\"|${sq}[^${sq}]*${sq}|(\\\\.|[^[:space:];&|\\\\])+)[[:space:]]*(&&|;)"
if [[ $before =~ $cd_re ]]; then
  tokenize "cd ${BASH_REMATCH[2]}"
  if [ "${#TOK[@]}" -ge 2 ]; then repo="$(resolve_dir "$repo" "${TOK[1]}")"; fi
fi

# git options between `git` and `commit`: -C <dir> and -c key=value.
gitopts="${m#*git}"
gitopts="${gitopts%commit}"
tokenize "$gitopts"
cfg_args=()
i=0
while [ "$i" -lt "${#TOK[@]}" ]; do
  case "${TOK[$i]}" in
    -C)
      i=$((i + 1))
      if [ "$i" -lt "${#TOK[@]}" ]; then repo="$(resolve_dir "$repo" "${TOK[$i]}")"; fi
      ;;
    -c)
      i=$((i + 1))
      if [ "$i" -lt "${#TOK[@]}" ]; then cfg_args[${#cfg_args[@]}]="-c"; cfg_args[${#cfg_args[@]}]="${TOK[$i]}"; fi
      ;;
  esac
  i=$((i + 1))
done

if [ ! -d "$repo" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  warn "could not resolve a git repo for the commit ('$repo'); identity not verified."
  return 0
fi

# Inline environment variables right before git (GIT_AUTHOR_NAME=x git commit).
env_args=()
seg="${before##*[;&|(\`{]}"
tokenize "$seg"
for t in ${TOK[@]+"${TOK[@]}"}; do
  case "$t" in
    GIT_AUTHOR_NAME=* | GIT_AUTHOR_EMAIL=* | GIT_COMMITTER_NAME=* | GIT_COMMITTER_EMAIL=*)
      v="${t#*=}"
      v="${v%"${v##*[![:space:]]}"}"
      env_args[${#env_args[@]}]="${t%%=*}=${v}"
      ;;
  esac
done

# --author="Name <email>" (after `commit`).
author_override=""
tokenize "$after"
i=0
while [ "$i" -lt "${#TOK[@]}" ]; do
  case "${TOK[$i]}" in
    --author=*) author_override="${TOK[$i]#--author=}" ;;
    --author)
      i=$((i + 1))
      if [ "$i" -lt "${#TOK[@]}" ]; then author_override="${TOK[$i]}"; fi
      ;;
  esac
  i=$((i + 1))
done

# --- Effective identity -------------------------------------------------------
# If git var fails (no identity configured) it is treated as empty.
get_ident() {
  env ${env_args[@]+"${env_args[@]}"} git -C "$repo" ${cfg_args[@]+"${cfg_args[@]}"} var "$1" 2>/dev/null
}
ident_name() { local v="$1"; printf '%s' "${v%% <*}"; }
ident_email() { local v="$1"; v="${v#*<}"; printf '%s' "${v%%>*}"; }

a_raw="$(get_ident GIT_AUTHOR_IDENT)" || a_raw=""
c_raw="$(get_ident GIT_COMMITTER_IDENT)" || c_raw=""
if [ -n "$a_raw" ]; then a_name="$(ident_name "$a_raw")"; a_email="$(ident_email "$a_raw")"; else a_name=""; a_email=""; fi
if [ -n "$c_raw" ]; then c_name="$(ident_name "$c_raw")"; c_email="$(ident_email "$c_raw")"; else c_name=""; c_email=""; fi

if [ -n "$author_override" ]; then
  case "$author_override" in
    *"<"*">"*)
      a_name="${author_override%%<*}"
      a_name="${a_name%"${a_name##*[![:space:]]}"}"
      a_email="${author_override#*<}"
      a_email="${a_email%%>*}"
      ;;
    *)
      # No email: git looks up an existing author; not verifiable here.
      warn "--author not in 'Name <email>' format; author not verified."
      a_name="$EXP_NAME"
      a_email="$EXP_EMAIL"
      ;;
  esac
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
want_email="$(lower "$EXP_EMAIL")"
ok=1
[ "$a_name" = "$EXP_NAME" ] || ok=0
[ "$c_name" = "$EXP_NAME" ] || ok=0
[ "$(lower "$a_email")" = "$want_email" ] || ok=0
[ "$(lower "$c_email")" = "$want_email" ] || ok=0
[ "$ok" -eq 1 ] && return 0

clean() { printf '%s' "$1" | LC_ALL=C tr -cd '[:print:]' | cut -c1-100; }
{
  echo "check-git-identity: commit blocked: the git identity does not match the expected one."
  echo "  author    : current name='$(clean "$a_name")' current email='$(clean "$a_email")'"
  echo "  committer : current name='$(clean "$c_name")' current email='$(clean "$c_email")'"
  echo "  expected  : name='$(clean "$EXP_NAME")' email='$(clean "$EXP_EMAIL")'"
  echo "Fix it with:"
  printf '  git config user.name %q && git config user.email %q\n' "$EXP_NAME" "$EXP_EMAIL"
} >&2
  return 2
}

command -v git >/dev/null 2>&1 || { warn "git not available; identity not verified."; exit 0; }

# Expected identity (see header).
EXP_NAME=""
EXP_EMAIL=""
if [ -n "${NODICLAUDE_GIT_NAME:-}" ] && [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  EXP_NAME="$NODICLAUDE_GIT_NAME"
  EXP_EMAIL="$NODICLAUDE_GIT_EMAIL"
elif [ -n "${NODICLAUDE_GIT_NAME:-}" ] || [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  warn "only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set (both are required); identity not verified."
  exit 0
else
  EXP_NAME="$(git config --global user.name 2>/dev/null)" || EXP_NAME=""
  EXP_EMAIL="$(git config --global user.email 2>/dev/null)" || EXP_EMAIL=""
  if [ -z "$EXP_NAME" ] || [ -z "$EXP_EMAIL" ]; then
    warn "no identity source (neither NODICLAUDE_GIT_NAME/EMAIL nor git config --global user.name/user.email); identity not verified."
    exit 0
  fi
fi

# All `git commit`s in the command are evaluated; one mismatch is enough to block.
rest="$command_str"
consumed=""
status=0
while [[ $rest =~ $commit_re ]]; do
  m="${BASH_REMATCH[0]}"
  # Text before and after the detected fragment.
  case "$m" in
    *commit)
      before="${rest%"$m"}"
      after=""
      ;;
    *)
      before="${rest%%"$m"*}"
      after="${rest#*"$m"}"
      after="${m: -1}${after}"
      m="${m%?}"
      ;;
  esac
  before="${consumed}${before}"
  check_one || status=2
  consumed="${before}${m}"
  rest="$after"
done
exit "$status"
