#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks `git commit` if the effective identity
# (author and committer) does not match the expected identity, which is resolved as follows:
#   1. NODICLAUDE_GIT_NAME and NODICLAUDE_GIT_EMAIL, if both are set.
#   2. otherwise, ~/.claude/.nodiclaude-identity (line 1 = name, line 2 = email), written by
#      install.sh when it was run with those variables (cloud).
#   3. otherwise, `git config --global --includes user.name` and `user.email` evaluated for the
#      target repo, so `includeIf` sections apply and repo-local config does not (local).
#   4. otherwise, warn and allow (exit 0). With only one of the two variables, it also warns and allows.
#
# The command is parsed like a shell would split it (quotes, escapes, comments, heredocs,
# `$(...)`, backticks, subshells, `bash -c '...'`), and only a `git` that runs as a command
# with the `commit` subcommand counts. Text that only mentions `git commit` (an argument,
# a quoted string, a heredoc body, a comment) is never checked, so it is never blocked.
#
# It is a "best effort" safeguard: it does not detect aliases (e.g. `git ci`), dynamically
# built commands (variables, eval, scripts) or commits made outside the Bash tool.
# On any unexpected failure (missing jq/git, invalid input, directory that is not a repo,
# expected identity not resolvable) it warns on stderr and allows the command (exit 0).
# It only blocks (exit 2) on a real mismatch.
#
# Input: JSON on stdin with tool_input.command and cwd.
# Bash 3.2 compatible (macOS): no mapfile, associative arrays, namerefs or ${var,,}.

warn() { echo "check-git-identity: warning: $*" >&2; }

command -v jq >/dev/null 2>&1 || { warn "jq not available; git identity not verified."; exit 0; }

input="$(cat)" || { warn "could not read the hook input."; exit 0; }
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)" ||
  { warn "invalid hook input."; exit 0; }
[ -n "$command_str" ] || exit 0

# Cheap pre-check: without both words there is nothing to parse.
case "$command_str" in *git*) ;; *) exit 0 ;; esac
case "$command_str" in *commit*) ;; *) exit 0 ;; esac

command -v git >/dev/null 2>&1 || { warn "git not available; identity not verified."; exit 0; }

# Byte-wise string handling in this shell only (not exported to git).
LC_ALL=C

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)" || cwd=""
[ -n "$cwd" ] || cwd="."

# --- Expected identity, sources 1 and 2 (see header) ---------------------------------
# Empty means: resolve per repo (source 3).
FIXED_NAME=""
FIXED_EMAIL=""
if [ -n "${NODICLAUDE_GIT_NAME:-}" ] && [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  FIXED_NAME="$NODICLAUDE_GIT_NAME"
  FIXED_EMAIL="$NODICLAUDE_GIT_EMAIL"
elif [ -n "${NODICLAUDE_GIT_NAME:-}" ] || [ -n "${NODICLAUDE_GIT_EMAIL:-}" ]; then
  warn "only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set (both are required); identity not verified."
  exit 0
elif [ -f "$HOME/.claude/.nodiclaude-identity" ]; then
  FIXED_NAME="$(sed -n 1p "$HOME/.claude/.nodiclaude-identity" 2>/dev/null | tr -d '\r')"
  FIXED_EMAIL="$(sed -n 2p "$HOME/.claude/.nodiclaude-identity" 2>/dev/null | tr -d '\r')"
  if [ -z "$FIXED_NAME" ] || [ -z "$FIXED_EMAIL" ]; then
    warn "$HOME/.claude/.nodiclaude-identity is incomplete; identity not verified (run install.sh again)."
    exit 0
  fi
fi

# --- Helpers ----------------------------------------------------------------------
# Resolves directory $2 relative to $1 (supports a leading ~ or $HOME, and absolute paths).
resolve_dir() {
  local base="$1" d="$2"
  # The literal "~" typed in the command is matched on purpose.
  # shellcheck disable=SC2088
  case "$d" in
    "~" | '$HOME' | '${HOME}') d="$HOME" ;;
    "~/"*) d="$HOME/${d#"~/"}" ;;
    '$HOME/'*) d="$HOME/${d#'$HOME/'}" ;;
    '${HOME}/'*) d="$HOME/${d#'${HOME}/'}" ;;
  esac
  case "$d" in
    /*) printf '%s' "$d" ;;
    *) printf '%s/%s' "$base" "$d" ;;
  esac
}

# git environment variables that change the identity or the repo of a commit.
is_git_env() {
  case "$1" in
    GIT_AUTHOR_NAME=* | GIT_AUTHOR_EMAIL=* | GIT_COMMITTER_NAME=* | GIT_COMMITTER_EMAIL=* | GIT_DIR=* | GIT_WORK_TREE=*) return 0 ;;
  esac
  return 1
}

# --- Identity check of one `git commit` ------------------------------------------------
# Uses: CK_DIR (the shell's directory), CK_GARGS (git options that pick the repo: -C,
# --git-dir, --work-tree), CK_CFG (-c options), CK_ENV (NAME=value), CK_AUTHOR (--author value).
# Returns 0 (ok or not verifiable) or 2 (block).
check_commit() {
  local exp_name exp_email a_raw c_raw a_name a_email c_name c_email want_email ok
  if [ ! -d "$CK_DIR" ] || ! env ${CK_ENV[@]+"${CK_ENV[@]}"} git -C "$CK_DIR" ${CK_GARGS[@]+"${CK_GARGS[@]}"} rev-parse --git-dir >/dev/null 2>&1; then
    warn "could not resolve a git repo for the commit ('$CK_DIR'); identity not verified."
    return 0
  fi

  # Expected identity: sources 1 and 2 were resolved once; source 3 depends on the repo.
  exp_name="$FIXED_NAME"
  exp_email="$FIXED_EMAIL"
  if [ -z "$exp_name" ]; then
    exp_name="$(env ${CK_ENV[@]+"${CK_ENV[@]}"} git -C "$CK_DIR" ${CK_GARGS[@]+"${CK_GARGS[@]}"} config --global --includes user.name 2>/dev/null)" || exp_name=""
    exp_email="$(env ${CK_ENV[@]+"${CK_ENV[@]}"} git -C "$CK_DIR" ${CK_GARGS[@]+"${CK_GARGS[@]}"} config --global --includes user.email 2>/dev/null)" || exp_email=""
    if [ -z "$exp_name" ] || [ -z "$exp_email" ]; then
      warn "no identity source (neither NODICLAUDE_GIT_NAME/EMAIL, ~/.claude/.nodiclaude-identity nor git config --global user.name/user.email); identity not verified."
      return 0
    fi
  fi

  # Effective identity (repo config, environment and the command's own -c and variables).
  # If git var fails (no identity configured) it is treated as empty.
  a_raw="$(env ${CK_ENV[@]+"${CK_ENV[@]}"} git -C "$CK_DIR" ${CK_GARGS[@]+"${CK_GARGS[@]}"} ${CK_CFG[@]+"${CK_CFG[@]}"} var GIT_AUTHOR_IDENT 2>/dev/null)" || a_raw=""
  c_raw="$(env ${CK_ENV[@]+"${CK_ENV[@]}"} git -C "$CK_DIR" ${CK_GARGS[@]+"${CK_GARGS[@]}"} ${CK_CFG[@]+"${CK_CFG[@]}"} var GIT_COMMITTER_IDENT 2>/dev/null)" || c_raw=""
  a_name="${a_raw%% <*}"
  a_email="${a_raw#*<}"
  a_email="${a_email%%>*}"
  c_name="${c_raw%% <*}"
  c_email="${c_raw#*<}"
  c_email="${c_email%%>*}"
  [ -n "$a_raw" ] || { a_name=""; a_email=""; }
  [ -n "$c_raw" ] || { c_name=""; c_email=""; }

  if [ -n "$CK_AUTHOR" ]; then
    case "$CK_AUTHOR" in
      *"<"*">"*)
        a_name="${CK_AUTHOR%%<*}"
        a_name="${a_name%"${a_name##*[![:space:]]}"}"
        a_email="${CK_AUTHOR#*<}"
        a_email="${a_email%%>*}"
        ;;
      *)
        # No email: git looks up an existing author; not verifiable here.
        warn "--author not in 'Name <email>' format; author not verified."
        a_name="$exp_name"
        a_email="$exp_email"
        ;;
    esac
  fi

  want_email="$(printf '%s' "$exp_email" | tr '[:upper:]' '[:lower:]')"
  ok=1
  [ "$a_name" = "$exp_name" ] || ok=0
  [ "$c_name" = "$exp_name" ] || ok=0
  [ "$(printf '%s' "$a_email" | tr '[:upper:]' '[:lower:]')" = "$want_email" ] || ok=0
  [ "$(printf '%s' "$c_email" | tr '[:upper:]' '[:lower:]')" = "$want_email" ] || ok=0
  [ "$ok" -eq 1 ] && return 0

  clean() { printf '%s' "$1" | tr -cd '[:print:]' | cut -c1-100; }
  {
    echo "check-git-identity: commit blocked: the git identity does not match the expected one."
    echo "  author    : current name='$(clean "$a_name")' current email='$(clean "$a_email")'"
    echo "  committer : current name='$(clean "$c_name")' current email='$(clean "$c_email")'"
    echo "  expected  : name='$(clean "$exp_name")' email='$(clean "$exp_email")'"
    echo "Fix it with:"
    printf '  git config user.name %q && git config user.email %q\n' "$exp_name" "$exp_email"
  } >&2
  return 2
}

# --- Shell parser -------------------------------------------------------------------
# State: S (text), P (position), N (length); CTX_DIR (directory after `cd`/`pushd`);
# CTX_ENV (git variables set with `export`); INH_ENV (variables passed down to `bash -c`);
# HD_D/HD_S (pending heredoc delimiters and their <<- flag). The current command's words
# (W), word (cur, inw) and redirection flag (redir) are locals of parse_list, which the
# helpers below see through bash's dynamic scoping.
STATUS=0
CTX_DIR="$cwd"
CTX_ENV=()
INH_ENV=()
HD_D=()
HD_S=()

endword() {
  if [ "$inw" -eq 1 ]; then
    if [ "$redir" -eq 1 ]; then
      redir=0 # redirection target, not a word of the command
    else
      W[${#W[@]}]="$cur"
    fi
  fi
  cur=""
  inw=0
}

# Skips the bodies of the heredocs started on the line that just ended.
skip_heredocs() {
  local k rest line cmp body d
  k=0
  while [ "$k" -lt "${#HD_D[@]}" ]; do
    d="${HD_D[$k]}"
    if [ "${HD_S[$k]}" -eq 0 ]; then
      # Fast path: find the delimiter line with one pattern match instead of line by line.
      rest="${S:$P}"
      if [ "$rest" = "$d" ] || [ "${rest#"$d"$'\n'}" != "$rest" ]; then
        body=""
      else
        body="${rest%%$'\n'"$d"$'\n'*}"
        if [ "$body" = "$rest" ]; then body="${rest%$'\n'"$d"}"; fi
        if [ "$body" = "$rest" ]; then P=$N; k=$((k + 1)); continue; fi # no delimiter: runs to the end
        body="$body"$'\n'
      fi
      P=$((P + ${#body} + ${#d} + 1))
      [ "$P" -le "$N" ] || P=$N
      k=$((k + 1))
      continue
    fi
    while [ "$P" -lt "$N" ]; do
      rest="${S:$P}"
      line="${rest%%$'\n'*}"
      if [ "$line" = "$rest" ]; then P=$N; else P=$((P + ${#line} + 1)); fi
      cmp="$line"
      if [ "${HD_S[$k]}" -eq 1 ]; then cmp="${cmp#"${cmp%%[!$'\t']*}"}"; fi
      [ "$cmp" = "$d" ] && break
    done
    k=$((k + 1))
  done
  HD_D=()
  HD_S=()
}

# Reads a heredoc operator at P (just after `<<`) and registers its delimiter.
read_heredoc() {
  local strip=0 delim="" c q=""
  if [ "${S:$P:1}" = "-" ]; then strip=1; P=$((P + 1)); fi
  while [ "$P" -lt "$N" ]; do
    c="${S:$P:1}"
    case "$c" in ' ' | $'\t') P=$((P + 1)) ;; *) break ;; esac
  done
  while [ "$P" -lt "$N" ]; do
    c="${S:$P:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""; else delim="$delim$c"; fi
      P=$((P + 1))
      continue
    fi
    case "$c" in
      "'" | '"') q="$c" ;;
      '\') P=$((P + 1)); delim="$delim${S:$P:1}" ;;
      ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '<' | '>' | '(' | ')') break ;;
      *) delim="$delim$c" ;;
    esac
    P=$((P + 1))
  done
  case "$delim" in
    "" | *[!0-9]*) ;;
    *) return 0 ;; # digits only: an arithmetic shift such as $((1<<2)), not a heredoc
  esac
  [ -n "$delim" ] || return 0
  HD_D[${#HD_D[@]}]="$delim"
  HD_S[${#HD_S[@]}]="$strip"
}

# Parses a nested command list ($( ), backticks, subshell) in its own directory and
# environment context: a `cd` inside does not leak out.
nested() { # nested <end>
  local saved_dir="$CTX_DIR"
  local saved_env=(${CTX_ENV[@]+"${CTX_ENV[@]}"})
  parse_list "$1"
  CTX_DIR="$saved_dir"
  CTX_ENV=(${saved_env[@]+"${saved_env[@]}"})
}

# Reads a double-quoted string at P (just after the opening quote) into cur.
dquote() {
  local c n rest chunk
  while [ "$P" -lt "$N" ]; do
    rest="${S:$P}"
    chunk="${rest%%[\"\\\$\`]*}"
    if [ -n "$chunk" ]; then
      cur="$cur$chunk"
      P=$((P + ${#chunk}))
      continue
    fi
    c="${S:$P:1}"
    case "$c" in
      '"') P=$((P + 1)); return 0 ;;
      '\')
        n="${S:$((P + 1)):1}"
        case "$n" in
          '"' | '\' | '$' | '`') cur="$cur$n"; P=$((P + 2)) ;;
          $'\n') P=$((P + 2)) ;;
          *) cur="$cur\\"; P=$((P + 1)) ;;
        esac
        ;;
      '$')
        if [ "${S:$((P + 1)):1}" = "(" ]; then
          P=$((P + 2)); nested ")"; cur="${cur}_"
        else
          cur="$cur\$"; P=$((P + 1))
        fi
        ;;
      '`') P=$((P + 1)); nested '`'; cur="${cur}_" ;;
    esac
  done
}

# Parses the text in S from P until the end, or until the closing $1 (")" or "`").
parse_list() {
  local end="$1" W=() cur="" inw=0 redir=0 c rest chunk
  while [ "$P" -lt "$N" ]; do
    rest="${S:$P}"
    chunk="${rest%%[[:space:]\;\&\|\(\)\`\$\'\"\\\#\<\>]*}"
    if [ -n "$chunk" ]; then
      cur="$cur$chunk"
      inw=1
      P=$((P + ${#chunk}))
      continue
    fi
    c="${S:$P:1}"
    case "$c" in
      $'\n') endword; emit; P=$((P + 1)); skip_heredocs ;;
      ' ' | $'\t' | $'\r' | $'\f' | $'\v') endword; P=$((P + 1)) ;;
      ';' | '&' | '|') endword; emit; P=$((P + 1)) ;;
      '(')
        P=$((P + 1))
        if [ "$inw" -eq 0 ] && [ "${#W[@]}" -eq 0 ]; then
          nested ")"
        else
          cur="$cur("; inw=1
        fi
        ;;
      ')')
        endword; emit; P=$((P + 1))
        [ "$end" = ")" ] && return 0
        ;;
      '`')
        P=$((P + 1))
        if [ "$end" = '`' ]; then endword; emit; return 0; fi
        nested '`'; cur="${cur}_"; inw=1
        ;;
      '$')
        if [ "${S:$((P + 1)):1}" = "(" ]; then
          P=$((P + 2)); nested ")"; cur="${cur}_"
        else
          cur="$cur\$"; P=$((P + 1))
        fi
        inw=1
        ;;
      "'")
        P=$((P + 1))
        rest="${S:$P}"
        chunk="${rest%%\'*}"
        cur="$cur$chunk"
        P=$((P + ${#chunk} + 1))
        inw=1
        ;;
      '"') P=$((P + 1)); dquote; inw=1 ;;
      '\')
        if [ "${S:$((P + 1)):1}" = $'\n' ]; then
          P=$((P + 2))
        else
          cur="$cur${S:$((P + 1)):1}"; inw=1; P=$((P + 2))
        fi
        ;;
      '#')
        if [ "$inw" -eq 0 ]; then
          rest="${S:$P}"
          chunk="${rest%%$'\n'*}"
          P=$((P + ${#chunk}))
        else
          cur="$cur#"; P=$((P + 1))
        fi
        ;;
      '<' | '>')
        if [ "${S:$P:2}" = "<<" ] && [ "${S:$P:3}" != "<<<" ]; then
          endword; P=$((P + 2)); read_heredoc
        else
          # A file descriptor number right before the operator is not a word (2>&1).
          case "$cur" in "" | *[!0-9]*) endword ;; *) cur=""; inw=0 ;; esac
          P=$((P + 1))
          while [ "$P" -lt "$N" ]; do
            case "${S:$P:1}" in '<' | '>' | '&') P=$((P + 1)) ;; *) break ;; esac
          done
          redir=1
        fi
        ;;
      *) cur="$cur$c"; inw=1; P=$((P + 1)) ;;
    esac
  done
  endword
  emit
}

# Parses a whole script (for `bash -c '...'`) with its own position and heredoc state.
parse_string() { # parse_string <text>
  local sS="$S" sP="$P" sN="$N"
  local sD=(${HD_D[@]+"${HD_D[@]}"}) sH=(${HD_S[@]+"${HD_S[@]}"})
  S="$1"
  P=0
  N=${#S}
  HD_D=()
  HD_S=()
  parse_list ""
  S="$sS"
  P="$sP"
  N="$sN"
  HD_D=(${sD[@]+"${sD[@]}"})
  HD_S=(${sH[@]+"${sH[@]}"})
}

# Handles the command in W (then clears it): `cd`/`pushd`, `export`, `bash -c`, `git commit`.
emit() {
  local n=${#W[@]} i=0 w b j sub found script envs=() saved_dir saved_inh
  if [ "$n" -eq 0 ]; then return 0; fi
  # Keywords, wrappers and NAME=value assignments before the command.
  while [ "$i" -lt "$n" ]; do
    w="${W[$i]}"
    case "$w" in
      '{' | '!' | if | then | do | else | elif | while | until | time | nohup | command | exec | builtin)
        i=$((i + 1))
        ;;
      sudo | doas)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${W[$i]}" in
            -u | -g | -C | -D | -h | -p | -U | -r | -t | -T) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${W[$i]}" in
            -u | -C | -S) i=$((i + 2)) ;;
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      nice)
        i=$((i + 1))
        case "${W[$i]}" in -n) i=$((i + 2)) ;; -*) i=$((i + 1)) ;; esac
        ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${W[$i]}" in
            -s | -k) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        i=$((i + 1)) # duration
        ;;
      [A-Za-z_]*=*)
        case "${w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
        if is_git_env "$w"; then envs[${#envs[@]}]="$w"; fi
        i=$((i + 1))
        ;;
      *) break ;;
    esac
  done
  if [ "$i" -ge "$n" ]; then W=(); return 0; fi

  b="${W[$i]##*/}"
  case "$b" in
    cd | pushd)
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        case "${W[$j]}" in --) j=$((j + 1)); break ;; -?*) j=$((j + 1)) ;; *) break ;; esac
      done
      if [ "$j" -ge "$n" ]; then
        CTX_DIR="$HOME"
      elif [ "${W[$j]}" != "-" ]; then
        CTX_DIR="$(resolve_dir "$CTX_DIR" "${W[$j]}")"
      fi
      ;;
    export)
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        if is_git_env "${W[$j]}"; then CTX_ENV[${#CTX_ENV[@]}]="${W[$j]}"; fi
        j=$((j + 1))
      done
      ;;
    bash | sh | zsh | dash | ksh)
      # bash [options] -c 'script': the script is the first argument after the options.
      j=$((i + 1))
      found=0
      while [ "$j" -lt "$n" ]; do
        case "${W[$j]}" in
          --) j=$((j + 1)); break ;;
          -o | +o) j=$((j + 2)) ;;
          --*) j=$((j + 1)) ;;
          -*c*) found=1; j=$((j + 1)) ;;
          [-+]*) j=$((j + 1)) ;;
          *) break ;;
        esac
      done
      if [ "$found" -eq 1 ] && [ "$j" -lt "$n" ]; then
        script="${W[$j]}"
        saved_dir="$CTX_DIR"
        saved_inh=(${INH_ENV[@]+"${INH_ENV[@]}"})
        INH_ENV=(${INH_ENV[@]+"${INH_ENV[@]}"} ${CTX_ENV[@]+"${CTX_ENV[@]}"} ${envs[@]+"${envs[@]}"})
        local saved_ctx_env=(${CTX_ENV[@]+"${CTX_ENV[@]}"})
        CTX_ENV=()
        parse_string "$script"
        CTX_DIR="$saved_dir"
        CTX_ENV=(${saved_ctx_env[@]+"${saved_ctx_env[@]}"})
        INH_ENV=(${saved_inh[@]+"${saved_inh[@]}"})
      fi
      ;;
    git)
      # git [global options] <subcommand> [arguments]
      CK_GARGS=()
      CK_CFG=()
      sub=""
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        w="${W[$j]}"
        case "$w" in
          -C)
            j=$((j + 1))
            CK_GARGS[${#CK_GARGS[@]}]="-C"
            CK_GARGS[${#CK_GARGS[@]}]="$(resolve_dir . "${W[$j]}")"
            ;;
          -c)
            j=$((j + 1))
            CK_CFG[${#CK_CFG[@]}]="-c"
            CK_CFG[${#CK_CFG[@]}]="${W[$j]}"
            ;;
          --git-dir=* | --work-tree=*) CK_GARGS[${#CK_GARGS[@]}]="$w" ;;
          --git-dir | --work-tree)
            j=$((j + 1))
            CK_GARGS[${#CK_GARGS[@]}]="$w=${W[$j]}"
            ;;
          --namespace | --super-prefix | --config-env) j=$((j + 1)) ;;
          -*) ;;
          *) sub="$w"; break ;;
        esac
        j=$((j + 1))
      done
      if [ "$sub" = "commit" ]; then
        CK_AUTHOR=""
        j=$((j + 1))
        while [ "$j" -lt "$n" ]; do
          case "${W[$j]}" in
            --) break ;;
            --author=*) CK_AUTHOR="${W[$j]#--author=}" ;;
            --author) j=$((j + 1)); CK_AUTHOR="${W[$j]}" ;;
          esac
          j=$((j + 1))
        done
        CK_DIR="$CTX_DIR"
        CK_ENV=(${INH_ENV[@]+"${INH_ENV[@]}"} ${CTX_ENV[@]+"${CTX_ENV[@]}"} ${envs[@]+"${envs[@]}"})
        check_commit || STATUS=2
      fi
      ;;
  esac
  W=()
}

# All `git commit`s in the command are evaluated; one mismatch is enough to block.
S=""
P=0
N=0
parse_string "$command_str"
exit "$STATUS"
