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
unset NODICLAUDE_GIT_NAME NODICLAUDE_GIT_EMAIL

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

# Variables win over the global config
run_hook_raw "$T/good" "git commit -m x" NODICLAUDE_GIT_NAME=Another NODICLAUDE_GIT_EMAIL=another@x.io
check "hook: variables win over global (blocks)" 2 "$RC"
mkrepo "$T/anotherid" "Another" "another@x.io"
run_hook_raw "$T/anotherid" "git commit -m x" NODICLAUDE_GIT_NAME=Another NODICLAUDE_GIT_EMAIL=another@x.io
check "hook: variables win over global (allows)" 0 "$RC"
: > "$GIT_CONFIG_GLOBAL"

printf 'this is not json' | NODICLAUDE_GIT_NAME=a NODICLAUDE_GIT_EMAIL=b bash "$HOOK" >/dev/null 2>&1
check "hook: garbage input => 0" 0 "$?"
printf '' | NODICLAUDE_GIT_NAME=a NODICLAUDE_GIT_EMAIL=b bash "$HOOK" >/dev/null 2>&1
check "hook: empty input => 0" 0 "$?"

# --- install.sh -------------------------------------------------------------------
echo "== install.sh =="
newhome() { rm -rf "$T/home"; mkdir -p "$T/home"; : > "$GIT_CONFIG_GLOBAL"; }
copyrepo() { rm -rf "$T/repocopy"; mkdir -p "$T/repocopy"; (cd "$ROOT" && tar --exclude=.git -cf - .) | (cd "$T/repocopy" && tar -xf -); }
inst() { # inst <install.sh> -> OUT and RC
  OUT="$(bash "$1" 2>&1)"
  RC=$?
}
S="$HOME/.claude/settings.json"

newhome
git config --global user.name "Prim Era"
git config --global user.email "prim@x.io"
inst "$ROOT/install.sh"
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
inst "$ROOT/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "install: second run identical" || ko "install: second run identical"
echo "$OUT" | grep -q "backup" && ko "install: no backups if nothing changed" || ok "install: no backups if nothing changed"

# commit identity
tree_of() { (cd "$HOME" && find . 2>/dev/null | LC_ALL=C sort); }
newhome
inst "$ROOT/install.sh"
check "install: no identity => rc 1" 1 "$RC"
echo "$OUT" | grep -q "ERROR" && echo "$OUT" | grep -q "NODICLAUDE_GIT_NAME" && echo "$OUT" | grep -q "git config --global" && ok "install: no identity explains the error" || ko "install: no identity explains the error" "$OUT"
check "install: no identity creates nothing" "." "$(tree_of)"
check "install: no identity does not touch gitconfig" "" "$(cat "$GIT_CONFIG_GLOBAL")"

newhome
NODICLAUDE_GIT_NAME="Only Name" inst "$ROOT/install.sh"
check "install: only NAME => rc 1" 1 "$RC"
echo "$OUT" | grep -q "Set both or neither" && ok "install: only NAME explains the error" || ko "install: only NAME explains the error" "$OUT"
check "install: only NAME creates nothing" "." "$(tree_of)"
NODICLAUDE_GIT_EMAIL="only@x.io" inst "$ROOT/install.sh"
check "install: only EMAIL => rc 1" 1 "$RC"
check "install: only EMAIL creates nothing" "." "$(tree_of)"
check "install: only one variable does not touch gitconfig" "" "$(cat "$GIT_CONFIG_GLOBAL")"

# local: global config present, no variables
newhome
git config --global user.name "Loc Al"
git config --global user.email "loc@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
inst "$ROOT/install.sh"
check "install: global without variables rc" 0 "$RC"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: global without variables does not modify gitconfig" || ko "install: global without variables does not modify gitconfig"
echo "$OUT" | grep -q "Loc Al" && ok "install: global without variables logs the identity" || ko "install: global without variables logs the identity" "$OUT"

# cloud: variables and empty global config
newhome
NODICLAUDE_GIT_NAME="N Uno" NODICLAUDE_GIT_EMAIL="n@x.io" inst "$ROOT/install.sh"
check "install: variables and empty global rc" 0 "$RC"
check "install: writes user.name" "N Uno" "$(git config --global user.name)"
check "install: writes user.email" "n@x.io" "$(git config --global user.email)"
echo "$OUT" | grep -q "written" && ok "install: logs what was written" || ko "install: logs what was written" "$OUT"

# cloud: global with other values => not overwritten, WARNING
newhome
git config --global user.name "Other Name"
git config --global user.email "another@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
NODICLAUDE_GIT_NAME="N Dos" NODICLAUDE_GIT_EMAIL="n2@x.io" inst "$ROOT/install.sh"
check "install: variables and different global rc" 0 "$RC"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: different global is not modified" || ko "install: different global is not modified"
echo "$OUT" | grep -q "WARNING.*user.name" && echo "$OUT" | grep -q "WARNING.*user.email" && ok "install: different global warns" || ko "install: different global warns" "$OUT"

echo "$OUT" | grep -q "NODICLAUDE_GIT_NAME requires" && echo "$OUT" | grep -q "NODICLAUDE_GIT_EMAIL requires" && ok "install: WARNING names the variables in uppercase" || ko "install: WARNING names the variables in uppercase" "$OUT"

# cloud: same global => no changes
newhome
git config --global user.name "N Tres"
git config --global user.email "n3@x.io"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before"
NODICLAUDE_GIT_NAME="N Tres" NODICLAUDE_GIT_EMAIL="n3@x.io" inst "$ROOT/install.sh"
cmp -s "$GIT_CONFIG_GLOBAL" "$T/gitconfig.before" && ok "install: same global unchanged" || ko "install: same global unchanged"
echo "$OUT" | grep -q "WARNING.*user\." && ko "install: same global does not warn" "$OUT" || ok "install: same global does not warn"

# cloud: partial global => only the missing key is written
newhome
git config --global user.name "Partial"
NODICLAUDE_GIT_NAME="Another" NODICLAUDE_GIT_EMAIL="p@x.io" inst "$ROOT/install.sh"
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
inst "$ROOT/install.sh"
check "install: existing settings rc" 0 "$RC"
check "install: keeps other keys" "opus" "$(jq -r .model "$S")"
check "install: keeps other hooks" "/other/hook.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
check "install: keeps foreign events" "/stop.sh" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")"
check "install: matcher change without duplicating" "1:Bash" "$(jq -r '[.hooks.PreToolUse[] | select(.hooks[0].command | endswith("check-git-identity.sh"))] | "\(length):\(.[0].matcher)"' "$S")"
cp "$S" "$T/settings.run1"
inst "$ROOT/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "install: idempotent merge" || ko "install: idempotent merge"

# invalid settings
newhome
mkdir -p "$HOME/.claude"
echo '{ not json' > "$S"
NODICLAUDE_GIT_NAME="Inv" NODICLAUDE_GIT_EMAIL="inv@x.io" inst "$ROOT/install.sh"
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
inst "$ROOT/install.sh"
check "install: non-array PreToolUse rc" 0 "$RC"
check "install: non-array PreToolUse untouched" '{"hooks":{"PreToolUse":"weird"}}' "$(cat "$S")"

# settings as a symlink
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
mkdir -p "$HOME/.claude"
echo '{"model":"x"}' > "$T/real-settings.json"
ln -s "$T/real-settings.json" "$S"
inst "$ROOT/install.sh"
[ -L "$S" ] && ok "install: settings is still a symlink" || ko "install: settings is still a symlink"
check "install: wrote to the symlink target" "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' "$T/real-settings.json")"

# backup when a destination changes
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
bash "$ROOT/install.sh" >/dev/null 2>&1
echo "# modified" >> "$HOME/.claude/agents/audit-auditor.md"
inst "$ROOT/install.sh"
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
inst "$ROOT/install.sh"
echo "$OUT" | grep -q "symlink" && [ "$(cat "$T/mine.md")" = "mine" ] && ok "install: symlink destination skipped" || ko "install: symlink destination skipped"

# manifest entry that is a directory
newhome
NODICLAUDE_GIT_NAME="Dir" NODICLAUDE_GIT_EMAIL="dir@x.io" bash "$ROOT/install.sh" >/dev/null 2>&1
mkdir -p "$HOME/.claude/hooks/dir"
printf 'hooks/dir\n' >> "$HOME/.claude/.nodiclaude-manifest"
rm -f "$S"
NODICLAUDE_GIT_NAME="Dir" NODICLAUDE_GIT_EMAIL="dir@x.io" inst "$ROOT/install.sh"
check "install: directory in manifest rc" 0 "$RC"
[ -d "$HOME/.claude/hooks/dir" ] && ok "install: manifest directory untouched" || ko "install: manifest directory untouched"
jq -e '.hooks.PreToolUse' "$S" >/dev/null 2>&1 && ok "install: settings created after directory in manifest" || ko "install: settings after directory in manifest"
check "install: identity after directory in manifest" "Dir" "$(git config --global user.name)"

# rules/
newhome
git config --global user.name "T Est"
git config --global user.email "t@x.io"
inst "$ROOT/install.sh"
cmp -s "$ROOT/rules/git-commits.md" "$HOME/.claude/rules/git-commits.md" && ok "install: rules/git-commits.md installed" || ko "install: rules/git-commits.md installed"
grep -Fxq "rules/git-commits.md" "$HOME/.claude/.nodiclaude-manifest" && ok "install: the rule is in the manifest" || ko "install: the rule is in the manifest"
inst "$ROOT/install.sh"
echo "$OUT" | grep -q "(0 files copied)" && ok "install: second run copies 0 files" || ko "install: second run copies 0 files" "$OUT"
echo "# modified" >> "$HOME/.claude/rules/git-commits.md"
inst "$ROOT/install.sh"
bk="$(find "$HOME/.claude/.nodiclaude-backup" -type f -name git-commits.md 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -q "# modified" "$bk" && ok "install: backup of the modified rule" || ko "install: backup of the modified rule"
cmp -s "$ROOT/rules/git-commits.md" "$HOME/.claude/rules/git-commits.md" && ok "install: rule restored" || ko "install: rule restored"
copyrepo
rm -f "$T/repocopy/rules/git-commits.md"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ ! -e "$HOME/.claude/rules/git-commits.md" ] && ok "install: removed rule deleted" || ko "install: removed rule deleted"
newhome
inst "$ROOT/install.sh"
[ ! -e "$HOME/.claude/rules" ] && ok "install: no identity does not create rules/" || ko "install: no identity does not create rules/"

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
for pair in 'https://u:p@ss@host/x|https://host/x' 'git@github.com:o/r.git|git@github.com:o/r.git' 'https://github.com/o/r.git|https://github.com/o/r.git' 'https://tok@host/a@b|https://host/a@b'; do
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
printf 'checked=abc\nremote=zzz\nnotified=\x01\x02\n' > "$CF"
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
inst "$ROOT/install.sh"
check "settings: SessionStart command" '$HOME/.claude/hooks/check-update.sh session-start' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$S")"
check "settings: UserPromptSubmit command" '$HOME/.claude/hooks/check-update.sh prompt' "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$S")"
check "settings: PreToolUse still there" '$HOME/.claude/hooks/check-git-identity.sh' "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
check "settings: timeouts" "10:5" "$(jq -r '"\(.hooks.SessionStart[0].hooks[0].timeout):\(.hooks.UserPromptSubmit[0].hooks[0].timeout)"' "$S")"
cp "$S" "$T/settings.run1"
inst "$ROOT/install.sh"
cmp -s "$S" "$T/settings.run1" && ok "settings: second run byte-identical" || ko "settings: second run byte-identical"
check "settings: no duplicates" "1:1:1" "$(jq -r '"\(.hooks.PreToolUse|length):\(.hooks.SessionStart|length):\(.hooks.UserPromptSubmit|length)"' "$S")"
copyrepo
rm -f "$T/repocopy/hooks/check-update.sh"
jq 'del(.hooks.SessionStart, .hooks.UserPromptSubmit)' "$T/repocopy/settings.json" > "$T/s.json" && cp "$T/s.json" "$T/repocopy/settings.json"
bash "$T/repocopy/install.sh" >/dev/null 2>&1
[ ! -e "$HOME/.claude/hooks/check-update.sh" ] && ok "settings: removed check-update.sh deleted" || ko "settings: removed check-update.sh deleted"
grep -q "check-update" "$S" && ko "settings: removed hook entries dropped" "$(cat "$S")" || ok "settings: removed hook entries dropped"
check "settings: other hooks kept after removal" '$HOME/.claude/hooks/check-git-identity.sh' "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"

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
