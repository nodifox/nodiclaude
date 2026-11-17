#!/usr/bin/env bash
# nodiclaude tests: check-git-identity hook, install.sh and repo consistency.
# Uses a temporary HOME, repos and GIT_CONFIG_GLOBAL; does not touch the real config.
# Bash 3.2 compatible.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
ko() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ ($2)}"; }
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "expected=$2 actual=$3"; fi
}

export HOME="$T/home"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
: > "$GIT_CONFIG_GLOBAL"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset NODICLAUDE_GIT_NAME NODICLAUDE_GIT_EMAIL NODICLAUDE_ALLOW_ANY_BRANCH
# Git config passed through the environment (e.g. by cloud platforms) would leak into the tests.
unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_DIR GIT_WORK_TREE
for v in $(env | grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+=' | cut -d= -f1); do unset "$v"; done

GOOD_NAME="Good Name"
GOOD_EMAIL="good@example.com"
HOOK="$ROOT/hooks/check-git-identity.sh"

mkrepo() { # mkrepo <dir> <name> <email>
  mkdir -p "$1"
  git init -q "$1"
  git -C "$1" config user.name "$2"
  git -C "$1" config user.email "$3"
}

# run_hook <cwd> <command> -> sets RC and ERR
run_hook() {
  local json
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  ERR="$(printf '%s' "$json" | NODICLAUDE_GIT_NAME="$GOOD_NAME" NODICLAUDE_GIT_EMAIL="$GOOD_EMAIL" bash "$HOOK" 2>&1 >/dev/null)"
  RC=$?
}
hook_case() { # hook_case <name> <expected rc> <cwd> <command>
  run_hook "$3" "$4"
  check "hook: $1" "$2" "$RC"
}

echo "== hook =="
mkrepo "$T/good" "$GOOD_NAME" "$GOOD_EMAIL"
mkrepo "$T/bad" "Bad Name" "bad@example.com"
mkrepo "$T/my dir" "$GOOD_NAME" "$GOOD_EMAIL"
mkrepo "$T/other" "Bad Name" "bad@example.com"
mkdir -p "$T/plain"

hook_case "no commit" 0 "$T/bad" "git status"
hook_case "correct commit" 0 "$T/good" "git commit -m x"
hook_case "commit with wrong identity" 2 "$T/bad" "git commit -m x"
hook_case "chained with ;" 2 "$T/bad" "git add -A; git commit -m x"
hook_case "chained with &&" 2 "$T/bad" "git add -A && git commit -m x"
hook_case "/usr/bin/git commit" 2 "$T/bad" "/usr/bin/git commit -m x"
hook_case "bash -c" 2 "$T/bad" 'bash -c "git commit -m x"'
hook_case "git -C with spaces" 2 "$T/good" "git -C \"$T/my dir\" -c user.name=Bad commit -m x"
hook_case "git -C with spaces, correct" 0 "$T/bad" "git -C \"$T/my dir\" commit -m x"
hook_case "git -C other repo, wrong" 2 "$T/good" "git -C $T/other commit -m x"
hook_case "git -C relative" 2 "$T" "git -C other commit -m x"
hook_case "git --no-pager commit" 2 "$T/bad" "git --no-pager commit -m x"
hook_case "cd dir && git commit" 2 "$T/good" "cd $T/other && git commit -m x"
hook_case "relative cd && git commit" 0 "$T" "cd good && git commit -m x"
hook_case "-c user.name=Bad in correct repo" 2 "$T/good" "git -c user.name=Bad commit -m x"
hook_case "-c user.name/email correct in wrong repo" 0 "$T/bad" "git -c user.name='$GOOD_NAME' -c user.email=$GOOD_EMAIL commit -m x"
hook_case "inline GIT_AUTHOR_NAME wrong" 2 "$T/good" "GIT_AUTHOR_NAME=Bad git commit -m x"
hook_case "inline GIT_AUTHOR_NAME/EMAIL and COMMITTER correct" 0 "$T/bad" "GIT_AUTHOR_NAME='$GOOD_NAME' GIT_AUTHOR_EMAIL=$GOOD_EMAIL GIT_COMMITTER_NAME='$GOOD_NAME' GIT_COMMITTER_EMAIL=$GOOD_EMAIL git commit -m x"
hook_case "--author wrong" 2 "$T/good" "git commit --author=\"Bad <bad@example.com>\" -m x"
hook_case "--author correct" 0 "$T/good" "git commit --author=\"$GOOD_NAME <$GOOD_EMAIL>\" -m x"
mkrepo "$T/upper" "$GOOD_NAME" "GOOD@Example.COM"
hook_case "email case-insensitive" 0 "$T/upper" "git commit -m x"
mkrepo "$T/lowername" "good name" "$GOOD_EMAIL"
hook_case "name case-sensitive" 2 "$T/lowername" "git commit -m x"
hook_case "git log --grep commit does not match" 0 "$T/bad" "git log --grep commit"
hook_case "git commit-tree does not match" 0 "$T/bad" "git commit-tree HEAD^{tree}"
hook_case "git log | grep commit does not match" 0 "$T/bad" "git log --oneline | grep commit"
hook_case "value with mixed quotes" 2 "$T/good" "git -c user.name=\"Evil Guy\" commit -m x"
mkrepo "$T/other x" "Bad Name" "bad@example.com"
hook_case "-C with escaped space (wrong repo)" 2 "$T/good" "git -C $T/other\\ x commit -m x"
hook_case "cd with escaped space" 2 "$T/good" "cd $T/other\\ x && git commit -m x"
hook_case "several commits, the second wrong" 2 "$T" "git -C good commit -m a && git -C \"other x\" commit -m b"
hook_case "several correct commits" 0 "$T" "git -C good commit -m a && git -C \"my dir\" commit -m b"
hook_case "outside a repo" 0 "$T/plain" "git commit -m x"
hook_case "cd, newline, git commit" 2 "$T/good" "cd $T/other
git commit -m x"
hook_case "cd, newline, git commit (correct repo)" 0 "$T/bad" "cd $T/good
git commit -m x"
hook_case "bash -c with cd" 2 "$T/good" "bash -c \"cd $T/other && git commit -m x\""
hook_case "cd&&git without spaces" 2 "$T/good" "cd $T/other&&git commit -m x"
hook_case "cd;git without spaces" 2 "$T/good" "cd $T/other;git commit -m x"
hook_case "cd || exit; git commit" 2 "$T/good" "cd $T/other || exit 1; git commit -m x"
hook_case "pushd && git commit" 2 "$T/good" "pushd $T/other && git commit -m x"
hook_case "inline variable after a newline" 2 "$T/good" "echo a
GIT_AUTHOR_EMAIL=bad@example.com git commit -m x"

# No false positives: `git commit` that is only text, never a command that runs
hook_case "no fp: grep for the text" 0 "$T/bad" 'grep -rn "git commit" .'
hook_case "no fp: echo quoted" 0 "$T/bad" 'echo "git commit"'
hook_case "no fp: echo unquoted" 0 "$T/bad" 'echo git commit -m x'
hook_case "no fp: single-quoted argument" 0 "$T/bad" "gh pr create --body 'Then run git commit to finish'"
hook_case "no fp: git log --grep with the text" 0 "$T/bad" 'git log --grep "git commit"'
hook_case "no fp: pipe into grep" 0 "$T/bad" "git log --oneline | grep 'git commit'"
hook_case "no fp: heredoc body" 0 "$T/bad" "cat > notes.md <<'EOF'
Then run git commit -m x
EOF"
hook_case "no fp: heredoc with <<-" 0 "$T/bad" "cat <<-EOF
	git commit -m x
	EOF
echo done"
hook_case "no fp: comment" 0 "$T/bad" "ls # then git commit -m x"
hook_case "no fp: escaped quotes in a string" 0 "$T/bad" 'echo "say \"git commit\" now"'
hook_case "no fp: git commit-tree" 0 "$T/bad" "git commit-tree HEAD^{tree} -m x"
hook_case "no fp: commit as an argument" 0 "$T/bad" "git show commit"

# Still detected
hook_case "heredoc message with parens" 2 "$T/bad" "git commit -m \"\$(cat <<'EOF'
Fix things (and more)
EOF
)\""
hook_case "command after a heredoc" 2 "$T/bad" "cat > f <<'EOF'
text
EOF
git commit -m x"
hook_case "commit inside \$( )" 2 "$T/bad" 'echo "$(git commit -m x)"'
hook_case "commit inside backticks" 2 "$T/bad" 'echo `git commit -m x`'
hook_case "quoted git word" 2 "$T/bad" '"git" commit -m x'
hook_case "subshell with cd" 2 "$T/good" "(cd $T/other && git commit -m x)"
hook_case "cd inside a subshell does not leak" 0 "$T/good" "(cd $T/other && ls); git commit -m x"
hook_case "chained relative cds" 2 "$T" "cd good && cd ../other && git commit -m x"
hook_case "export then commit" 2 "$T/good" "export GIT_AUTHOR_EMAIL=bad@example.com; git commit -m x"
hook_case "GIT_DIR to another repo" 2 "$T/good" "GIT_DIR=$T/other/.git GIT_WORK_TREE=$T/other git commit -m x"
hook_case "--git-dir to another repo" 2 "$T/good" "git --git-dir=$T/other/.git --work-tree=$T/other commit -m x"
hook_case "if git commit" 2 "$T/bad" "if git commit -m x; then echo ok; fi"
hook_case "timeout wrapper" 2 "$T/bad" "timeout 10 git commit -m x"
hook_case "env wrapper" 2 "$T/good" "env GIT_AUTHOR_NAME=Bad git commit -m x"
hook_case "sh -lc" 2 "$T/good" "sh -lc 'cd $T/other && git commit -m x'"
hook_case "redirections" 2 "$T/bad" "git commit -m x 2>&1 >/dev/null"
hook_case "cd with redirection" 2 "$T/good" "cd $T/other 2>/dev/null && git commit -m x"
hook_case "line continuation" 2 "$T/bad" "git \\
  commit -m x"

run_hook "$T/bad" "git commit -m x"
case "$ERR" in *"git config user.name"*"Bad Name"*|*"Bad Name"*"git config user.name"*) ok "hook: the message includes the fix command" ;; *) ko "hook: block message" "$ERR" ;; esac

# run_hook_raw <cwd> <command> [VAR=value...] -> RC and ERR; no NODICLAUDE_* variables except those passed
run_hook_raw() {
  local json d="$1" c="$2"
  shift 2
  json="$(jq -n --arg c "$c" --arg d "$d" '{tool_input:{command:$c},cwd:$d}')"
  ERR="$(printf '%s' "$json" | env "$@" bash "$HOOK" 2>&1 >/dev/null)"
  RC=$?
}

# No variables and no global config => warns and allows
: > "$GIT_CONFIG_GLOBAL"
run_hook_raw "$T/bad" "git commit -m x" A=1
check "hook: no identity source => 0" 0 "$RC"
case "$ERR" in *"warning"*"identity source"*) ok "hook: no source warns" ;; *) ko "hook: no source warns" "$ERR" ;; esac

# Only one variable => warns and allows (even with a global config)
git config --global user.name "$GOOD_NAME"
git config --global user.email "$GOOD_EMAIL"
run_hook_raw "$T/bad" "git commit -m x" NODICLAUDE_GIT_NAME=Only
check "hook: only one variable => 0" 0 "$RC"
case "$ERR" in *"warning"*"only one"*) ok "hook: only one variable warns" ;; *) ko "hook: only one variable warns" "$ERR" ;; esac

# No variables, expected identity = global config
run_hook_raw "$T/bad" "git commit -m x" A=1
check "hook: global, commit with different identity => 2" 2 "$RC"
case "$ERR" in *"$GOOD_NAME"*"git config user.name"*|*"git config user.name"*"$GOOD_NAME"*) ok "hook: global, the message uses the global identity" ;; *) ko "hook: global, message" "$ERR" ;; esac
run_hook_raw "$T/good" "git commit -m x" A=1
check "hook: global, commit with same identity => 0" 0 "$RC"
mkrepo "$T/noident" "$GOOD_NAME" "$GOOD_EMAIL"
git -C "$T/noident" config --unset user.name
git -C "$T/noident" config --unset user.email
run_hook_raw "$T/noident" "git commit -m x" A=1
check "hook: global, repo inherits the global identity => 0" 0 "$RC"

# includeIf: the expected identity is the global one as it applies to the target repo
mkdir -p "$T/work"
mkrepo "$T/work/r" "$GOOD_NAME" "work@example.com"
mkrepo "$T/work/personal" "$GOOD_NAME" "$GOOD_EMAIL"
# git matches gitdir: against the repo's real path (on macOS mktemp -d is under the /var symlink).
TREAL="$(cd -P "$T" && pwd)"
printf '[includeIf "gitdir:%s/work/"]\n\tpath = %s/work.inc\n' "$TREAL" "$T" >> "$GIT_CONFIG_GLOBAL"
printf '[user]\n\temail = work@example.com\n' > "$T/work.inc"
run_hook_raw "$T/work/r" "git commit -m x" A=1
check "hook: includeIf, work identity in work repo => 0" 0 "$RC"
run_hook_raw "$T/work/personal" "git commit -m x" A=1
check "hook: includeIf, personal identity in work repo => 2" 2 "$RC"
case "$ERR" in *"user.email work@example.com"*) ok "hook: includeIf, fix command uses the work email" ;; *) ko "hook: includeIf, fix command" "$ERR" ;; esac
run_hook_raw "$T/good" "git commit -m x" A=1
check "hook: includeIf, personal identity outside work => 0" 0 "$RC"
git config --global user.name "$GOOD_NAME"
git config --global user.email "$GOOD_EMAIL"

# Variables win over the global config
run_hook_raw "$T/good" "git commit -m x" NODICLAUDE_GIT_NAME=Another NODICLAUDE_GIT_EMAIL=another@x.io
check "hook: variables win over global (blocks)" 2 "$RC"
mkrepo "$T/anotherid" "Another" "another@x.io"
run_hook_raw "$T/anotherid" "git commit -m x" NODICLAUDE_GIT_NAME=Another NODICLAUDE_GIT_EMAIL=another@x.io
check "hook: variables win over global (allows)" 0 "$RC"

# Identity file written by install.sh: wins over the global config, loses to the variables
mkdir -p "$HOME/.claude"
printf 'Another\nanother@x.io\n' > "$HOME/.claude/.nodiclaude-identity"
run_hook_raw "$T/anotherid" "git commit -m x" A=1
check "hook: identity file, matching commit => 0" 0 "$RC"
run_hook_raw "$T/good" "git commit -m x" A=1
check "hook: identity file wins over global => 2" 2 "$RC"
run_hook_raw "$T/good" "git commit -m x" NODICLAUDE_GIT_NAME="$GOOD_NAME" NODICLAUDE_GIT_EMAIL="$GOOD_EMAIL"
check "hook: variables win over identity file => 0" 0 "$RC"
printf 'OnlyName\n' > "$HOME/.claude/.nodiclaude-identity"
run_hook_raw "$T/bad" "git commit -m x" A=1
check "hook: incomplete identity file => 0" 0 "$RC"
case "$ERR" in *"warning"*"incomplete"*) ok "hook: incomplete identity file warns" ;; *) ko "hook: incomplete identity file warns" "$ERR" ;; esac
rm -f "$HOME/.claude/.nodiclaude-identity"
: > "$GIT_CONFIG_GLOBAL"

printf 'this is not json' | NODICLAUDE_GIT_NAME=a NODICLAUDE_GIT_EMAIL=b bash "$HOOK" >/dev/null 2>&1
check "hook: garbage input => 0" 0 "$?"
printf '' | NODICLAUDE_GIT_NAME=a NODICLAUDE_GIT_EMAIL=b bash "$HOOK" >/dev/null 2>&1
check "hook: empty input => 0" 0 "$?"

# --- install.sh -------------------------------------------------------------------
echo "== install.sh =="
newhome() { rm -rf "${T:?}/home"; mkdir -p "$T/home"; : > "$GIT_CONFIG_GLOBAL"; }
copyrepo() { rm -rf "$T/repocopy"; mkdir -p "$T/repocopy"; (cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$T/repocopy" && tar -xf -); }
inst() { # inst <install.sh> [options] -> OUT and RC
  OUT="$(bash "$@" 2>&1)"
  RC=$?
}
S="$HOME/.claude/settings.json"

# MAIN: temp git copy of the repo with branch forced to main, so the suite does not depend on
# the branch it is run from. Install tests run MAIN/install.sh.
MAIN="$T/maincopy"
mkdir -p "$MAIN"
(cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$MAIN" && tar -xf -)
git -C "$MAIN" init -q
git -C "$MAIN" symbolic-ref HEAD refs/heads/main
git -C "$MAIN" add -A
git -C "$MAIN" -c user.name=T -c user.email=t@x.io commit -q -m initial

newhome
git config --global user.name "Prim Era"
git config --global user.email "prim@x.io"
inst "$MAIN/install.sh"
check "install: first run" 0 "$RC"
expected="$(cd "$ROOT" && find skills agents hooks rules -type f ! -name .DS_Store | LC_ALL=C sort)"
actual="$(cd "$HOME/.claude" && find skills agents hooks rules -type f | LC_ALL=C sort)"
check "install: file list" "$expected" "$actual"
check "install: manifest" "$expected" "$(LC_ALL=C sort "$HOME/.claude/.nodiclaude-manifest")"
jq -e . "$S" >/dev/null 2>&1 && ok "install: valid settings.json" || ko "install: valid settings.json"
exec_ok=1
for f in "$ROOT"/hooks/*.sh; do [ -x "$HOME/.claude/hooks/$(basename "$f")" ] || exec_ok=0; done
check "install: executable hooks" 1 "$exec_ok"
cp "$S" "$T/settings.run1"
inst "$MAIN/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "install: second run identical" || ko "install: second run identical"
echo "$OUT" | grep -q "backup" && ko "install: no backups if nothing changed" || ok "install: no backups if nothing changed"

# commit identity
tree_of() { (cd "$HOME" && find . 2>/dev/null | LC_ALL=C sort); }
newhome
inst "$MAIN/install.sh"
check "install: no identity => rc 1" 1 "$RC"
echo "$OUT" | grep -q "ERROR" && echo "$OUT" | grep -q "NODICLAUDE_GIT_NAME" && echo "$OUT" | grep -q "git config --global" && ok "install: no identity explains the error" || ko "install: no identity explains the error" "$OUT"
check "install: no identity creates nothing" "." "$(tree_of)"
check "install: no identity does not touch gitconfig" "" "$(cat "$GIT_CONFIG_GLOBAL")"

newhome
NODICLAUDE_GIT_NAME="Only Name" inst "$MAIN/install.sh"
check "install: only NAME => rc 1" 1 "$RC"
echo "$OUT" | grep -q "Set both or neither" && ok "install: only NAME explains the error" || ko "install: only NAME explains the error" "$OUT"
check "install: only NAME creates nothing" "." "$(tree_of)"
NODICLAUDE_GIT_EMAIL="only@x.io" inst "$MAIN/install.sh"
check "install: only EMAIL => rc 1" 1 "$RC"
check "install: only EMAIL creates nothing" "." "$(tree_of)"
check "install: only one variable does not touch gitconfig" "" "$(cat "$GIT_CONFIG_GLOBAL")"

# local: global config present, no variables
newhome
git config --global user.name "Loc Al"
git config --global user.email "loc@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
mkdir -p "$HOME/.claude"
printf 'Old\nold@x.io\n' > "$HOME/.claude/.nodiclaude-identity"
inst "$MAIN/install.sh"
check "install: global without variables rc" 0 "$RC"
[ ! -e "$HOME/.claude/.nodiclaude-identity" ] && ok "install: global removes a stale identity file" || ko "install: global removes a stale identity file"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: global without variables does not modify gitconfig" || ko "install: global without variables does not modify gitconfig"
echo "$OUT" | grep -q "Loc Al" && ok "install: global without variables logs the identity" || ko "install: global without variables logs the identity" "$OUT"

# cloud: variables and empty global config
newhome
NODICLAUDE_GIT_NAME="N Uno" NODICLAUDE_GIT_EMAIL="n@x.io" inst "$MAIN/install.sh"
check "install: variables and empty global rc" 0 "$RC"
check "install: writes user.name" "N Uno" "$(git config --global user.name)"
check "install: writes user.email" "n@x.io" "$(git config --global user.email)"
echo "$OUT" | grep -q "written" && ok "install: logs what was written" || ko "install: logs what was written" "$OUT"
check "install: variables write the identity file" "N Uno|n@x.io" "$(sed -n 1p "$HOME/.claude/.nodiclaude-identity")|$(sed -n 2p "$HOME/.claude/.nodiclaude-identity")"

# cloud: global with other values => not overwritten, WARNING
newhome
git config --global user.name "Other Name"
git config --global user.email "another@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
NODICLAUDE_GIT_NAME="N Dos" NODICLAUDE_GIT_EMAIL="n2@x.io" inst "$MAIN/install.sh"
check "install: variables and different global rc" 0 "$RC"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: different global is not modified" || ko "install: different global is not modified"
echo "$OUT" | grep -q "WARNING.*user.name" && echo "$OUT" | grep -q "WARNING.*user.email" && ok "install: different global warns" || ko "install: different global warns" "$OUT"

echo "$OUT" | grep -q "NODICLAUDE_GIT_NAME requires" && echo "$OUT" | grep -q "NODICLAUDE_GIT_EMAIL requires" && ok "install: WARNING names the variables in uppercase" || ko "install: WARNING names the variables in uppercase" "$OUT"
check "install: different global still writes the identity file" "N Dos" "$(sed -n 1p "$HOME/.claude/.nodiclaude-identity")"
# Old cloud setup script (no --cloud) on an image with the platform identity: the installed
# hook must block commits made under the platform identity instead of letting them through.
newhome
git config --global user.name "Claude"
git config --global user.email "noreply@anthropic.com"
NODICLAUDE_GIT_NAME="Dev Eloper" NODICLAUDE_GIT_EMAIL="dev@x.io" inst "$MAIN/install.sh"
mkrepo "$T/platformid" "Claude" "noreply@anthropic.com"
git -C "$T/platformid" config --unset user.name
git -C "$T/platformid" config --unset user.email
ERR="$(jq -n --arg c "git commit -m x" --arg d "$T/platformid" '{tool_input:{command:$c},cwd:$d}' | bash "$HOME/.claude/hooks/check-git-identity.sh" 2>&1 >/dev/null)"
check "install: without --cloud, commits as the platform identity are blocked" 2 "$?"
case "$ERR" in *"Dev Eloper"*) ok "install: without --cloud, the block names the developer identity" ;; *) ko "install: block message names the developer" "$ERR" ;; esac

# --cloud: the setup script identity replaces the image's and commit signing is turned off
newhome
git config --global user.name "Claude"
git config --global user.email "noreply@anthropic.com"
git config --global commit.gpgsign true
NODICLAUDE_GIT_NAME="Dev Eloper" NODICLAUDE_GIT_EMAIL="dev@x.io" inst "$MAIN/install.sh" --cloud
check "cloud: rc" 0 "$RC"
check "cloud: overwrites user.name" "Dev Eloper" "$(git config --global user.name)"
check "cloud: overwrites user.email" "dev@x.io" "$(git config --global user.email)"
check "cloud: disables commit signing" "false" "$(git config --global commit.gpgsign)"
check "cloud: identity file" "Dev Eloper|dev@x.io" "$(sed -n 1p "$HOME/.claude/.nodiclaude-identity")|$(sed -n 2p "$HOME/.claude/.nodiclaude-identity")"
echo "$OUT" | grep -q "was 'Claude'" && ok "cloud: logs the replaced value" || ko "cloud: logs the replaced value" "$OUT"
NODICLAUDE_GIT_NAME="Dev Eloper" NODICLAUDE_GIT_EMAIL="dev@x.io" inst "$MAIN/install.sh" --cloud
echo "$OUT" | grep -q "git config --global .* written" && ko "cloud: second run writes nothing" "$OUT" || ok "cloud: second run writes nothing"
newhome
NODICLAUDE_GIT_NAME="" NODICLAUDE_GIT_EMAIL="" inst "$MAIN/install.sh" --cloud
check "cloud: empty identity => rc 1" 1 "$RC"
echo "$OUT" | grep -q "Fill in both" && ok "cloud: empty identity explains the fix" || ko "cloud: empty identity explains the fix" "$OUT"
check "cloud: empty identity creates nothing" "." "$(tree_of)"
git config --global user.name "Glob Al"
git config --global user.email "glob@x.io"
inst "$MAIN/install.sh" --cloud
check "cloud: global identity is not enough => rc 1" 1 "$RC"
inst "$MAIN/install.sh" --bogus
check "install: unknown option => rc 1" 1 "$RC"

# cloud: same global => no changes
newhome
git config --global user.name "N Tres"
git config --global user.email "n3@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
NODICLAUDE_GIT_NAME="N Tres" NODICLAUDE_GIT_EMAIL="n3@x.io" inst "$MAIN/install.sh"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: same global unchanged" || ko "install: same global unchanged"
echo "$OUT" | grep -q "WARNING.*user\." && ko "install: same global does not warn" "$OUT" || ok "install: same global does not warn"

# cloud: partial global => only the missing key is written
newhome
git config --global user.name "Partial"
NODICLAUDE_GIT_NAME="Another" NODICLAUDE_GIT_EMAIL="p@x.io" inst "$MAIN/install.sh"
check "install: partial global keeps name" "Partial" "$(git config --global user.name)"
check "install: partial global writes email" "p@x.io" "$(git config --global user.email)"

# existing settings
newhome
git config --global user.name "Set Ex"
git config --global user.email "set@x.io"
mkdir -p "$HOME/.claude"
cat > "$S" <<'JSON'
{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"/other/hook.sh"}]},{"matcher":"Read","hooks":[{"type":"command","command":"$HOME/.claude/hooks/check-git-identity.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/stop.sh"}]}]}}
JSON
inst "$MAIN/install.sh"
check "install: existing settings rc" 0 "$RC"
check "install: keeps other keys" "opus" "$(jq -r .model "$S")"
check "install: keeps other hooks" "/other/hook.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
check "install: keeps foreign events" "/stop.sh" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")"
check "install: matcher change without duplicating" "1:Bash" "$(jq -r '[.hooks.PreToolUse[] | select(.hooks[0].command | endswith("check-git-identity.sh"))] | "\(length):\(.[0].matcher)"' "$S")"
cp "$S" "$T/settings.run1"
inst "$MAIN/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "install: idempotent merge" || ko "install: idempotent merge"

# user hook sharing a group with a nodiclaude hook; argument change of a nodiclaude hook
newhome
git config --global user.name "Set Ex"
git config --global user.email "set@x.io"
mkdir -p "$HOME/.claude"
cat > "$S" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/myhook.sh"},{"type":"command","command":"$HOME/.claude/hooks/check-git-identity.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/check-update.sh prompt --old"}]}]}}
JSON
inst "$MAIN/install.sh"
check "merge: rc" 0 "$RC"
check "merge: user hook in a shared group kept" "1" "$(jq '[.hooks.PreToolUse[].hooks[].command | select(. == "/usr/local/bin/myhook.sh")] | length' "$S")"
check "merge: nodiclaude hook once" "1" "$(jq '[.hooks.PreToolUse[].hooks[].command | select(endswith("check-git-identity.sh"))] | length' "$S")"
check "merge: argument change replaces the old entry" '$HOME/.claude/hooks/check-update.sh prompt' "$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(",")' "$S")"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name settings.json 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q myhook "$bk" && ok "merge: settings.json backed up before the change" || ko "merge: settings.json backup"
cp "$S" "$T/settings.run1"
inst "$MAIN/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "merge: second run identical" || ko "merge: second run identical"

# whitespace-only settings is treated as empty
newhome
git config --global user.name "Set Ex"
git config --global user.email "set@x.io"
mkdir -p "$HOME/.claude"
printf '  \n' > "$S"
inst "$MAIN/install.sh"
check "install: whitespace-only settings replaced" "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' "$S" 2>/dev/null)"

# fresh install without jq: succeeds and says the identity hook is not working
NOJQ="$T/nojq"
mkdir -p "$NOJQ"
oldifs="$IFS"
IFS=:
for d in $PATH; do
  for f in "$d"/*; do
    b="${f##*/}"
    case "$b" in jq | apt-get | brew | apk | sudo) continue ;; esac
    [ -x "$f" ] && [ ! -e "$NOJQ/$b" ] && ln -s "$f" "$NOJQ/$b"
  done
done
IFS="$oldifs"
newhome
git config --global user.name "No Jq"
git config --global user.email "nojq@x.io"
PATH="$NOJQ" inst "$MAIN/install.sh"
check "no jq: fresh install rc" 0 "$RC"
echo "$OUT" | grep -q "jq is not installed" && ok "no jq: warns that the identity hook cannot verify" || ko "no jq: warning" "$OUT"
[ -s "$S" ] && ok "no jq: settings.json created" || ko "no jq: settings.json created"

# invalid settings
newhome
mkdir -p "$HOME/.claude"
echo '{ not json' > "$S"
NODICLAUDE_GIT_NAME="Inv" NODICLAUDE_GIT_EMAIL="inv@x.io" inst "$MAIN/install.sh"
check "install: invalid settings rc" 0 "$RC"
echo "$OUT" | grep -q "WARNING" && ok "install: invalid settings warns" || ko "install: invalid settings warns"
check "install: invalid settings untouched" '{ not json' "$(cat "$S")"
check "install: identity written despite invalid settings" "Inv" "$(git config --global user.name)"

# PreToolUse that is not an array
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
mkdir -p "$HOME/.claude"
echo '{"hooks":{"PreToolUse":"weird"}}' > "$S"
inst "$MAIN/install.sh"
check "install: non-array PreToolUse rc" 0 "$RC"
check "install: non-array PreToolUse untouched" '{"hooks":{"PreToolUse":"weird"}}' "$(cat "$S")"

# settings as a symlink
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
mkdir -p "$HOME/.claude"
echo '{"model":"x"}' > "$T/real-settings.json"
ln -s "$T/real-settings.json" "$S"
inst "$MAIN/install.sh"
[ -L "$S" ] && ok "install: settings is still a symlink" || ko "install: settings is still a symlink"
check "install: wrote to the symlink target" "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' "$T/real-settings.json")"

# backup when a destination changes
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
bash "$MAIN/install.sh" >/dev/null 2>&1
echo "# modified" >> "$HOME/.claude/agents/audit-auditor.md"
inst "$MAIN/install.sh"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name audit-auditor.md 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q "# modified" "$bk" && ok "install: backup of the modified destination" || ko "install: backup of the modified destination"
cmp -s "$ROOT/agents/audit-auditor.md" "$HOME/.claude/agents/audit-auditor.md" && ok "install: destination restored" || ko "install: destination restored"

# symlink as destination
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
mkdir -p "$HOME/.claude/agents"
echo "mine" > "$T/mine.md"
ln -s "$T/mine.md" "$HOME/.claude/agents/audit-auditor.md"
inst "$MAIN/install.sh"
echo "$OUT" | grep -q "symlink" && [ "$(cat "$T/mine.md")" = "mine" ] && ok "install: symlink destination skipped" || ko "install: symlink destination skipped"

# manifest entry that is a directory
newhome
NODICLAUDE_GIT_NAME="Dir" NODICLAUDE_GIT_EMAIL="dir@x.io" bash "$MAIN/install.sh" >/dev/null 2>&1
mkdir -p "$HOME/.claude/hooks/dir"
printf 'hooks/dir\n' >> "$HOME/.claude/.nodiclaude-manifest"
rm -f "$S"
NODICLAUDE_GIT_NAME="Dir" NODICLAUDE_GIT_EMAIL="dir@x.io" inst "$MAIN/install.sh"
check "install: directory in manifest rc" 0 "$RC"
[ -d "$HOME/.claude/hooks/dir" ] && ok "install: manifest directory untouched" || ko "install: manifest directory untouched"
jq -e '.hooks.PreToolUse' "$S" >/dev/null 2>&1 && ok "install: settings created after directory in manifest" || ko "install: settings after directory in manifest"
check "install: identity after directory in manifest" "Dir" "$(git config --global user.name)"

# rules/
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$MAIN/install.sh"
cmp -s "$ROOT/rules/git-commits.md" "$HOME/.claude/rules/git-commits.md" && ok "install: rules/git-commits.md installed" || ko "install: rules/git-commits.md installed"
grep -Fxq "rules/git-commits.md" "$HOME/.claude/.nodiclaude-manifest" && ok "install: the rule is in the manifest" || ko "install: the rule is in the manifest"
inst "$MAIN/install.sh"
echo "$OUT" | grep -q "(0 files copied)" && ok "install: second run copies 0 files" || ko "install: second run copies 0 files" "$OUT"
echo "# modified" >> "$HOME/.claude/rules/git-commits.md"
inst "$MAIN/install.sh"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name git-commits.md 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q "# modified" "$bk" && ok "install: backup of the modified rule" || ko "install: backup of the modified rule"
cmp -s "$ROOT/rules/git-commits.md" "$HOME/.claude/rules/git-commits.md" && ok "install: rule restored" || ko "install: rule restored"
copyrepo
rm -f "$T/repocopy/rules/git-commits.md"
echo "# user edit" >> "$HOME/.claude/rules/git-commits.md"
rm -rf "$HOME/.claude/.nodiclaude-backup"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ ! -e "$HOME/.claude/rules/git-commits.md" ] && ok "install: removed rule deleted" || ko "install: removed rule deleted"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name git-commits.md 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q "# user edit" "$bk" && ok "install: removed file backed up first" || ko "install: removed file backed up first"
newhome
inst "$MAIN/install.sh"
[ ! -e "$HOME/.claude/rules" ] && ok "install: no identity does not create rules/" || ko "install: no identity does not create rules/"

# symlinked directory pointing outside ~/.claude: nothing is written or removed there
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
rm -rf "$T/dotrules"
mkdir -p "$T/dotrules" "$HOME/.claude"
echo "mine" > "$T/dotrules/keep.md"
ln -s "$T/dotrules" "$HOME/.claude/rules"
inst "$MAIN/install.sh"
check "symlinked dir: rc" 0 "$RC"
echo "$OUT" | grep -q "outside" && ok "symlinked dir: warns" || ko "symlinked dir: warns" "$OUT"
[ ! -e "$T/dotrules/git-commits.md" ] && ok "symlinked dir: nothing copied outside" || ko "symlinked dir: copied outside"
printf 'rules/keep.md\n' >> "$HOME/.claude/.nodiclaude-manifest"
inst "$MAIN/install.sh"
[ -f "$T/dotrules/keep.md" ] && ok "symlinked dir: nothing removed outside" || ko "symlinked dir: removed outside"

# removal of retired files (on a copy of the repo)
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
copyrepo
mkdir -p "$T/repocopy/skills/extra" "$T/repocopy/hooks"
echo "x" > "$T/repocopy/skills/extra/SKILL.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/repocopy/hooks/extra.sh"
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/extra.sh"}]}]' "$T/repocopy/settings.json" > "$T/s.json" && cp "$T/s.json" "$T/repocopy/settings.json"
mkdir -p "$HOME/.claude/skills"
echo "mine" > "$HOME/.claude/skills/foreign.md"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ -f "$HOME/.claude/skills/extra/SKILL.md" ] && [ -f "$HOME/.claude/hooks/extra.sh" ] && ok "install: copy with extra files installed" || ko "install: copy with extra files installed"
grep -q extra.sh "$S" && ok "install: extra hook registered" || ko "install: extra hook registered"
rm -rf "$T/repocopy/skills/extra" "$T/repocopy/hooks/extra.sh"
jq 'del(.hooks.PreToolUse[] | select(.hooks[0].command | endswith("extra.sh")))' "$T/repocopy/settings.json" > "$T/s.json" && cp "$T/s.json" "$T/repocopy/settings.json"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ ! -e "$HOME/.claude/skills/extra" ] && ok "install: removed skill deleted and directory pruned" || ko "install: removed skill deleted"
[ ! -e "$HOME/.claude/hooks/extra.sh" ] && ok "install: removed hook deleted" || ko "install: removed hook deleted"
grep -q extra.sh "$S" && ko "install: removed hook entry in settings" || ok "install: removed hook entry dropped from settings"
[ -f "$HOME/.claude/skills/foreign.md" ] && ok "install: does not touch foreign files" || ko "install: does not touch foreign files"
jq -e . "$S" >/dev/null 2>&1 && ok "install: valid settings after removal" || ko "install: valid settings after removal"

# uninstall
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$MAIN/install.sh"
jq '.hooks.Stop = [{"hooks":[{"type":"command","command":"/mine/stop.sh"}]}] | .model = "mine"' "$S" > "$T/s.json" && cat "$T/s.json" > "$S"
echo "# edited" >> "$HOME/.claude/agents/quest-reviewer.md"
printf 'X\nx@x.io\n' > "$HOME/.claude/.nodiclaude-identity"
: > "$GIT_CONFIG_GLOBAL"
inst "$MAIN/install.sh" --uninstall
check "uninstall: rc (no identity needed)" 0 "$RC"
check "uninstall: installed files removed" "0" "$(find "$HOME/.claude/skills" "$HOME/.claude/agents" "$HOME/.claude/hooks" "$HOME/.claude/rules" -type f 2>/dev/null | wc -l | tr -d ' ')"
grep -q '/.claude/hooks/' "$S" && ko "uninstall: hook entries removed" "$(cat "$S")" || ok "uninstall: hook entries removed"
check "uninstall: other settings kept" "/mine/stop.sh|mine" "$(jq -r '"\(.hooks.Stop[0].hooks[0].command)|\(.model)"' "$S")"
check "uninstall: empty events dropped" "Stop" "$(jq -r '.hooks | keys | join(",")' "$S")"
left=""
for f in manifest version update-cache identity; do [ -e "$HOME/.claude/.nodiclaude-$f" ] && left="$left $f"; done
check "uninstall: state files removed" "" "$left"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name quest-reviewer.md 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q "# edited" "$bk" && ok "uninstall: edited file backed up" || ko "uninstall: edited file backed up"
inst "$MAIN/install.sh" --uninstall
check "uninstall: second run rc" 0 "$RC"
newhome
inst "$MAIN/install.sh" --uninstall
check "uninstall: nothing installed rc" 0 "$RC"

# source branch check
BR="$T/branchcopy"
rm -rf "$BR"; cp -R "$MAIN" "$BR"
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$BR/install.sh"
check "branch: on main installs" 0 "$RC"
git -C "$BR" checkout -q -b dev
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$BR/install.sh"
check "branch: other branch => rc 1" 1 "$RC"
echo "$OUT" | grep -q "ERROR" && echo "$OUT" | grep -q "'dev'" && echo "$OUT" | grep -q "NODICLAUDE_ALLOW_ANY_BRANCH" && ok "branch: message names branch and escape" || ko "branch: message names branch and escape" "$OUT"
check "branch: other branch creates nothing" "." "$(tree_of)"
NODICLAUDE_ALLOW_ANY_BRANCH=1 inst "$BR/install.sh"
check "branch: escape installs" 0 "$RC"
echo "$OUT" | grep -q "WARNING.*'dev'" && ok "branch: escape logs WARNING" || ko "branch: escape logs WARNING" "$OUT"
git -C "$BR" checkout -q --detach
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$BR/install.sh"
check "branch: detached HEAD => rc 1" 1 "$RC"
echo "$OUT" | grep -q "detached HEAD" && ok "branch: detached message" || ko "branch: detached message" "$OUT"
check "branch: detached HEAD creates nothing" "." "$(tree_of)"
NODICLAUDE_ALLOW_ANY_BRANCH=1 inst "$BR/install.sh"
check "branch: escape on detached HEAD installs" 0 "$RC"
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
copyrepo
inst "$T/repocopy/install.sh"
check "branch: no .git installs" 0 "$RC"
echo "$OUT" | grep -q "branch check skipped" && ok "branch: no .git logs skipped note" || ko "branch: no .git logs skipped note" "$OUT"
newhome
inst "$BR/install.sh"
check "branch: identity failure still rc 1" 1 "$RC"
echo "$OUT" | grep -q "could not determine Claude's commit identity" && ok "branch: identity failure still reported" || ko "branch: identity failure still reported" "$OUT"
check "branch: identity failure creates nothing" "." "$(tree_of)"

# tag named main, and branch named heads/main
TG="$T/tagcopy"
rm -rf "$TG"; cp -R "$MAIN" "$TG"
git -C "$TG" tag main
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$TG/install.sh"
check "branch: on main with a tag named main installs" 0 "$RC"
if git -C "$TG" checkout -q -b heads/main 2>/dev/null; then
  newhome
  git config --global user.name "T Est"
  git config --global user.email "t@x.io"
  inst "$TG/install.sh"
  check "branch: branch named heads/main => rc 1" 1 "$RC"
  echo "$OUT" | grep -q "'heads/main'" && ok "branch: heads/main reported as such" || ko "branch: heads/main reported as such" "$OUT"
  check "branch: heads/main creates nothing" "." "$(tree_of)"
fi

# --- check-update ---------------------------------------------------------------------
echo "== check-update =="
CU="$HOME/.claude/hooks/check-update.sh"
VF="$HOME/.claude/.nodiclaude-version"
CF="$HOME/.claude/.nodiclaude-update-cache"
BARE="$T/remote.git"
CLONE="$T/clone"
rm -rf "$BARE" "$CLONE" "$T/pusher"
git init -q --bare -b main "$BARE"
git clone -q "$BARE" "$CLONE" 2>/dev/null
git -C "$CLONE" config user.name "Dev"
git -C "$CLONE" config user.email "dev@x.io"
git -C "$CLONE" checkout -q -b main 2>/dev/null
(cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$CLONE" && tar -xf -)
git -C "$CLONE" add -A
git -C "$CLONE" commit -q -m "initial"
git -C "$CLONE" push -q origin main 2>/dev/null
H1="$(git -C "$CLONE" rev-parse HEAD)"

# version file
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$CLONE/install.sh"
check "version: install from clone rc" 0 "$RC"
check "version: line 1 is HEAD" "$H1" "$(sed -n 1p "$VF")"
check "version: line 2 is the origin URL" "$BARE" "$(sed -n 2p "$VF")"
check "version: only two lines" 2 "$(wc -l < "$VF" | tr -d ' ')"
grep -q "nodiclaude-version" "$HOME/.claude/.nodiclaude-manifest" && ko "version: not in the manifest" || ok "version: not in the manifest"
git -C "$CLONE" remote set-url origin "https://user:secret@example.invalid/org/repo.git"
inst "$CLONE/install.sh"
check "version: credentials stripped" "https://example.invalid/org/repo.git" "$(sed -n 2p "$VF")"
git -C "$CLONE" remote set-url origin "$BARE"
# credential stripping
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
for pair in 'ssh://git@github.com/o/r.git|ssh://git@github.com/o/r.git' 'https://u:p@ss@host/x|https://host/x' 'git@github.com:o/r.git|git@github.com:o/r.git' 'https://github.com/o/r.git|https://github.com/o/r.git' 'https://tok@host/a@b|https://host/a@b'; do
  git -C "$CLONE" remote set-url origin "${pair%%|*}"
  inst "$CLONE/install.sh"
  check "version: URL ${pair%%|*}" "${pair##*|}" "$(sed -n 2p "$VF")"
done
git -C "$CLONE" remote set-url origin "$BARE"
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
copyrepo
inst "$T/repocopy/install.sh"
check "version: non-git source rc" 0 "$RC"
[ ! -e "$VF" ] && ok "version: no file when the source is not a git repo" || ko "version: no file when the source is not a git repo"
echo "$OUT" | grep -q "version file not written" && ok "version: logs a note" || ko "version: logs a note" "$OUT"
newhome
inst "$CLONE/install.sh"
check "version: failure rc" 1 "$RC"
check "version: failure creates nothing" "." "$(tree_of)"

# helpers
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$CLONE/install.sh"
cu() { # cu <mode> -> CUOUT, CURC
  CUOUT="$(bash "$CU" "$1" 2>/dev/null </dev/null)"
  CURC=$?
}

# up to date
cu session-start
check "check-update: up to date rc" 0 "$CURC"
check "check-update: up to date prints nothing" "" "$CUOUT"
check "check-update: cache remote after session-start" "$H1" "$(grep '^remote=' "$CF" | cut -d= -f2)"
grep -q '^checked=[0-9]' "$CF" && ok "check-update: cache has checked" || ko "check-update: cache has checked"

# push a new commit
git clone -q "$BARE" "$T/pusher" 2>/dev/null
git -C "$T/pusher" config user.name "Dev"
git -C "$T/pusher" config user.email "dev@x.io"
echo more > "$T/pusher/new.txt"
git -C "$T/pusher" add -A
git -C "$T/pusher" commit -q -m "second"
git -C "$T/pusher" push -q origin main 2>/dev/null
H2="$(git -C "$T/pusher" rev-parse HEAD)"

cu session-start
check "check-update: outdated rc" 0 "$CURC"
case "$CUOUT" in *"${H1:0:7}"*"${H2:0:7}"*"# rev: ${H2:0:7}"*) ok "check-update: notice has both hashes and # rev:" ;; *) ko "check-update: notice" "$CUOUT" ;; esac
[ "$(printf '%s\n' "$CUOUT" | wc -l | tr -d ' ')" -le 3 ] && ok "check-update: notice is at most 3 lines" || ko "check-update: notice length"
check "check-update: notified recorded" "$H2" "$(grep '^notified=' "$CF" | cut -d= -f2)"
cu session-start
case "$CUOUT" in *"outdated"*) ok "check-update: session-start notifies every time" ;; *) ko "check-update: session-start repeats" "$CUOUT" ;; esac

# prompt: fresh cache, no network (URL replaced by a nonexistent path), already notified
printf '%s\n%s\n' "$H1" "$T/does-not-exist.git" > "$VF"
cu prompt
check "check-update: prompt already notified => silent" "" "$CUOUT"
check "check-update: prompt rc" 0 "$CURC"
# new remote hash in the cache => notifies once, then not again
sed -i.bak "s/^notified=.*/notified=/" "$CF" && rm -f "$CF.bak"
cu prompt
case "$CUOUT" in *"${H2:0:7}"*) ok "check-update: prompt notifies from the cache without network" ;; *) ko "check-update: prompt cached notice" "$CUOUT" ;; esac
cu prompt
check "check-update: prompt notifies once" "" "$CUOUT"

# prompt: stale cache + unreachable URL => quick and silent
sed -i.bak "s/^checked=.*/checked=1/;s/^notified=.*/notified=$H2/" "$CF" && rm -f "$CF.bak"
t0="$(date +%s)"
cu prompt
t1="$(date +%s)"
[ $((t1 - t0)) -lt 3 ] && ok "check-update: stale prompt returns quickly" || ko "check-update: stale prompt slow" "$((t1 - t0))s"
check "check-update: stale prompt silent" "" "$CUOUT"
check "check-update: stale prompt rc" 0 "$CURC"
sleep 1
grep -q '^checked=1$' "$CF" && ko "check-update: stale prompt marks checked (throttle)" || ok "check-update: stale prompt marks checked (throttle)"

# prompt: no cache, reachable URL => refreshed in the background
printf '%s\n%s\n' "$H1" "$BARE" > "$VF"
rm -f "$CF"
cu prompt
check "check-update: prompt without cache silent" "" "$CUOUT"
i=0
while [ $i -lt 50 ] && ! grep -q "^remote=$H2" "$CF" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
grep -q "^remote=$H2" "$CF" && ok "check-update: background refresh updated the cache" || ko "check-update: background refresh" "$(cat "$CF" 2>/dev/null)"
cu prompt
case "$CUOUT" in *"${H2:0:7}"*) ok "check-update: prompt notifies after refresh" ;; *) ko "check-update: prompt after refresh" "$CUOUT" ;; esac

# cache tied to the installed version
waitcache() { # waitcache <pattern>: waits up to 5s for the cache to match
  local n=0
  while [ $n -lt 50 ] && ! grep -q "$1" "$CF" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
}
NOW="$(date +%s)"
# (a) installed upgraded to the remote HEAD, old cache still fresh => silent, refreshed
printf '%s\n%s\n' "$H2" "$BARE" > "$VF"
printf 'installed=%s\nchecked=%s\nremote=%s\nnotified=\n' "$H1" "$NOW" "$H1" > "$CF"
cu prompt
check "check-update: stale-installed cache => prompt silent" "" "$CUOUT"
waitcache "^remote=$H2"
grep -q "^installed=$H2" "$CF" && grep -q "^remote=$H2" "$CF" && ok "check-update: invalid cache refreshed with installed= and remote=" || ko "check-update: invalid cache refresh" "$(cat "$CF" 2>/dev/null)"
cu prompt
check "check-update: after refresh prompt silent" "" "$CUOUT"
# (b) the bug scenario: installed == remote HEAD, stale cache with a different remote
printf 'installed=%s\nchecked=%s\nremote=%s\nnotified=\n' "$H1" "$NOW" "$H1" > "$CF"
cu prompt
check "check-update: bug scenario silent (1st prompt)" "" "$CUOUT"
waitcache "^remote=$H2"
cu prompt
check "check-update: bug scenario silent (2nd prompt)" "" "$CUOUT"
# (c) valid cache: notifies once per new remote hash, no network while fresh
printf '%s\n%s\n' "$H1" "$T/does-not-exist.git" > "$VF"
printf 'installed=%s\nchecked=%s\nremote=%s\nnotified=\n' "$H1" "$(date +%s)" "$H2" > "$CF"
cu prompt
case "$CUOUT" in *"${H2:0:7}"*) ok "check-update: valid cache notifies" ;; *) ko "check-update: valid cache notify" "$CUOUT" ;; esac
cu prompt
check "check-update: valid cache notifies once" "" "$CUOUT"
grep -q "^installed=$H1" "$CF" && ok "check-update: installed= kept on rewrite" || ko "check-update: installed= kept" "$(cat "$CF")"
# (d) old-format cache (no installed=) => invalid, silent, refreshed
printf '%s\n%s\n' "$H1" "$BARE" > "$VF"
printf 'checked=%s\nremote=%s\nnotified=\n' "$(date +%s)" "$H2" > "$CF"
cu prompt
check "check-update: old-format cache silent" "" "$CUOUT"
waitcache "^remote=$H2"
grep -q "^installed=$H1" "$CF" && grep -q "^remote=$H2" "$CF" && ok "check-update: old-format cache refreshed" || ko "check-update: old-format refresh" "$(cat "$CF")"
# (e) session-start with an invalid cache whose notified equals the remote => still notifies
printf 'checked=%s\nremote=%s\nnotified=%s\n' "$(date +%s)" "$H2" "$H2" > "$CF"
cu session-start
case "$CUOUT" in *"outdated"*) ok "check-update: session-start ignores stale notified" ;; *) ko "check-update: session-start stale notified" "$CUOUT" ;; esac
grep -q "^installed=$H1" "$CF" && ok "check-update: session-start writes installed=" || ko "check-update: session-start installed=" "$(cat "$CF")"

# option injection through the stored URL
INJ="$T/injected"
rm -f "$INJ" "$CF"
printf '%s\n%s\n' "$H1" "--upload-pack=touch $INJ" > "$VF"
cu session-start
check "check-update: option-like URL silent" "" "$CUOUT"
check "check-update: option-like URL rc" 0 "$CURC"
[ ! -e "$INJ" ] && ok "check-update: option-like URL runs nothing" || ko "check-update: option-like URL ran a command"
# '--' guards the call itself too
printf '%s\n%s\n' "$H1" " --upload-pack=touch $INJ" > "$VF"
cu session-start
[ ! -e "$INJ" ] && ok "check-update: leading-space option URL runs nothing" || ko "check-update: leading-space URL ran a command"

# GIT_SSH_COMMAND: set when unset, kept when set (fake git records its environment)
mkdir -p "$T/fakebin"
printf '#!/usr/bin/env bash\nprintf "%%s" "${GIT_SSH_COMMAND-UNSET}" > "$FAKE_OUT"\nexit 1\n' > "$T/fakebin/git"
chmod +x "$T/fakebin/git"
printf '%s\n%s\n' "$H1" "$BARE" > "$VF"
FAKE_OUT="$T/fake.out" PATH="$T/fakebin:$PATH" bash "$CU" session-start >/dev/null 2>&1 </dev/null
check "check-update: GIT_SSH_COMMAND defaults to BatchMode" "ssh -o BatchMode=yes" "$(cat "$T/fake.out")"
FAKE_OUT="$T/fake.out" GIT_SSH_COMMAND="ssh -i mykey" PATH="$T/fakebin:$PATH" bash "$CU" session-start >/dev/null 2>&1 </dev/null
check "check-update: user GIT_SSH_COMMAND kept" "ssh -i mykey" "$(cat "$T/fake.out")"

# silent failures
printf '%s\n%s\n' "$H1" "$T/does-not-exist.git" > "$VF"
rm -f "$CF"
cu session-start
check "check-update: unreachable URL silent" "" "$CUOUT"
check "check-update: unreachable URL rc" 0 "$CURC"
rm -f "$VF"
cu session-start
check "check-update: no version file silent" "" "$CUOUT"
check "check-update: no version file rc" 0 "$CURC"
cu prompt
check "check-update: no version file prompt silent" "" "$CUOUT"
printf '%s\n\n' "$H1" > "$VF"
cu session-start
check "check-update: empty URL silent" "" "$CUOUT"
printf 'garbage\n%s\n' "$BARE" > "$VF"
cu session-start
check "check-update: bad installed hash silent" "" "$CUOUT"
printf '%s\n%s\n' "$H1" "$BARE" > "$VF"
printf 'installed=%s\nchecked=abc\nremote=zzz\nnotified=\x01\x02\n' "$H1" > "$CF"
cu prompt
check "check-update: corrupt cache silent" "" "$CUOUT"
check "check-update: corrupt cache rc" 0 "$CURC"
cu bogus
check "check-update: unknown mode silent" "" "$CUOUT"
check "check-update: unknown mode rc" 0 "$CURC"

# settings
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$MAIN/install.sh"
check "settings: SessionStart command" '$HOME/.claude/hooks/check-update.sh session-start' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$S")"
check "settings: UserPromptSubmit command" '$HOME/.claude/hooks/check-update.sh prompt' "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$S")"
check "settings: PreToolUse still there" '$HOME/.claude/hooks/check-git-identity.sh' "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
check "settings: attribution empty" "::" "$(jq -r '"\(.attribution.commit):\(.attribution.pr):\(.attribution | length | if . == 2 then "" else "x" end)"' "$S")"
check "settings: timeouts" "10:5" "$(jq -r '"\(.hooks.SessionStart[0].hooks[0].timeout):\(.hooks.UserPromptSubmit[0].hooks[0].timeout)"' "$S")"
cp "$S" "$T/settings.run1"
inst "$MAIN/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "settings: second run byte-identical" || ko "settings: second run byte-identical"
check "settings: no duplicates" "1:1:1" "$(jq -r '"\(.hooks.PreToolUse|length):\(.hooks.SessionStart|length):\(.hooks.UserPromptSubmit|length)"' "$S")"
copyrepo
rm -f "$T/repocopy/hooks/check-update.sh"
jq 'del(.hooks.SessionStart, .hooks.UserPromptSubmit)' "$T/repocopy/settings.json" > "$T/s.json" && cp "$T/s.json" "$T/repocopy/settings.json"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ ! -e "$HOME/.claude/hooks/check-update.sh" ] && ok "settings: removed check-update.sh deleted" || ko "settings: removed check-update.sh deleted"
grep -q "check-update" "$S" && ko "settings: removed hook entries dropped" "$(cat "$S")" || ok "settings: removed hook entries dropped"
check "settings: other hooks kept after removal" '$HOME/.claude/hooks/check-git-identity.sh' "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"

# --- README cloud setup script -----------------------------------------------------
echo "== readme cloud setup script =="
SNIP="$T/cloud-setup.sh"
awk '
  /^## Cloud environment setup/ { in_sec = 1; next }
  in_sec && /^## / { exit }
  in_sec && !done && /^```bash[[:space:]]*$/ { in_blk = 1; next }
  in_blk && /^```[[:space:]]*$/ { in_blk = 0; done = 1; next }
  in_blk { print }
' "$ROOT/README.md" > "$SNIP"
[ -s "$SNIP" ] && ok "readme: cloud setup block extracted" || ko "readme: cloud setup block extracted"
bash -n "$SNIP" && ok "readme: cloud setup script is valid bash" || ko "readme: cloud setup script is valid bash"
for pat in '--branch main' '^# rev:' '^export NODICLAUDE_GIT_NAME=""$' '^export NODICLAUDE_GIT_EMAIL=""$' 'NODICLAUDE_GH_TOKEN' '\$DEST/install\.sh" --cloud'; do
  grep -q -- "$pat" "$SNIP" && ok "readme: cloud setup script contains $pat" || ko "readme: cloud setup script contains $pat"
done
# Dry run against a local repo standing in for the remote (copy of the snippet, test values).
newhome
BARE="$T/remote.git"
rm -rf "$BARE"
git clone -q --bare "$MAIN" "$BARE"
sed -e "s#^URL=.*#URL=\"file://$BARE\"#" \
    -e 's#^export NODICLAUDE_GIT_NAME=.*#export NODICLAUDE_GIT_NAME="Cloud Test"#' \
    -e 's#^export NODICLAUDE_GIT_EMAIL=.*#export NODICLAUDE_GIT_EMAIL="cloud@x.io"#' \
    "$SNIP" > "$T/cloud-setup.test.sh"
if grep -q "^URL=\"file://$BARE\"" "$T/cloud-setup.test.sh"; then
  ok "readme: dry run URL substituted with local repo"
  OUT="$(bash "$T/cloud-setup.test.sh" 2>&1)"
  RC=$?
  check "readme: cloud setup dry run exits 0" 0 "$RC"
  [ -f "$HOME/.claude/rules/git-commits.md" ] && ok "readme: cloud setup dry run installs rules/git-commits.md" || ko "readme: cloud setup dry run installs rules/git-commits.md" "$OUT"
  check "readme: cloud setup dry run writes identity" "Cloud Test" "$(git config --global user.name)"
  check "readme: cloud setup dry run disables signing" "false" "$(git config --global commit.gpgsign)"
  # Unfilled identity: the script fails and changes nothing.
  newhome
  sed -e "s#^URL=.*#URL=\"file://$BARE\"#" "$SNIP" > "$T/cloud-setup.unfilled.sh"
  OUT="$(bash "$T/cloud-setup.unfilled.sh" 2>&1)"
  RC=$?
  check "readme: unfilled identity => rc 1" 1 "$RC"
  check "readme: unfilled identity creates nothing" "." "$(tree_of)"
else
  ko "readme: dry run URL substituted with local repo"
  echo "SKIP: cloud setup dry run not executed (URL substitution failed)"
fi

# --- consistency --------------------------------------------------------------------
echo "== consistency =="
for a in audit-auditor audit-verifier quest-implementer quest-reviewer; do
  f="$ROOT/agents/$a.md"
  if [ -f "$f" ] && grep -q "^name: $a\$" "$f"; then ok "agent $a exists with matching name"; else ko "agent $a"; fi
  grep -rq "$a" "$ROOT/skills" && ok "agent $a is used by a skill" || ko "agent $a unused in skills"
done
while IFS= read -r c; do
  c="${c%% *}" # script path, without arguments
  base="$(basename "$c")"
  [ -f "$ROOT/hooks/$base" ] && ok "registered hook $base exists in hooks/" || ko "registered hook $base does not exist"
done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/settings.json")
for f in "$ROOT"/install.sh "$ROOT"/hooks/*.sh "$ROOT"/tests/run.sh; do
  bash -n "$f" && ok "syntax $(basename "$f")" || ko "syntax $(basename "$f")"
done

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
