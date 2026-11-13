# nodiclaude

Recommended Claude Code configuration for this organization's projects: shared skills, agents, rules and hooks, installed the same way on each developer's machine and in cloud environments (Claude Code on the web).

- **Locally**, each developer clones this repo and runs `./install.sh`. The configuration lands in `~/.claude`.
- **In the cloud**, the environment's setup script clones this repo and runs `install.sh`.

## Where it works

| Where | How it gets installed | What is verified |
|---|---|---|
| Terminal (Claude Code CLI) | Clone + `./install.sh` (see "Local install") | Claude Code documents that it loads `~/.claude/rules`. Not checked here in a real CLI session. |
| Claude desktop app (local sessions) | Same: clone + `./install.sh` | Rules in `~/.claude/rules` are loaded in a local session (observed in a real session). |
| Claude Code on the web / cloud environments (the same environment is used wherever the session is started; not verified for phone or tablet) | The environment's setup script (see "Cloud environment setup") | Rules in `~/.claude/rules` are loaded in a cloud session, also in subagents (observed in a real session). |

## Structure

```
skills/              # skills (skills/<name>/SKILL.md): audit, quest
agents/              # subagents (agents/<name>.md) used by the skills
hooks/               # hook scripts: check-git-identity.sh, check-update.sh
rules/               # user rules (rules/<name>.md) for Claude Code
settings.json        # hook registration and attribution settings (merged into ~/.claude/settings.json)
install.sh           # installs everything into $HOME/.claude (safe to run repeatedly); --cloud, --uninstall
tests/run.sh         # tests (hook, installer, README setup script and consistency)
.github/workflows/   # CI: tests on Ubuntu and macOS (bash 3.2), shellcheck
```

## Local install

```bash
git clone git@github.com:nodifox/nodiclaude.git
cd nodiclaude
./install.sh
```

- **Requirements:** git, bash, and macOS or Linux. `jq` is needed to merge `settings.json` and by the `check-git-identity` hook; if it is missing, `install.sh` tries to install it (`apt-get`, `brew` or `apk`) and warns if it cannot.
- **It needs:** a global git identity (`git config --global user.name` and `user.email`; `include` files are followed) and the repo on branch `main`.
- **Identity:** when it comes from the global git config, `install.sh` never writes to any gitconfig.
- **If it fails:** the message says why and nothing is changed. See "Troubleshooting".
- **Then:** start a new Claude Code session. Open sessions do not reload rules or hooks.

`install.sh` honors `$HOME`. The details are in "What `install.sh` does".

## Cloud environment setup

Fill in only the lines marked below, then paste the script into the environment's setup script field.

```bash
#!/usr/bin/env bash
# rev: initial
set -euo pipefail

# FILL IN: your full name, used for Claude's commits.
export NODICLAUDE_GIT_NAME=""
# FILL IN: your commit email (e.g. your GitHub no-reply address, id+username@users.noreply.github.com).
export NODICLAUDE_GIT_EMAIL=""
# OPTIONAL: read-only token for this repo; leave empty if the repo is public.
NODICLAUDE_GH_TOKEN=""

DEST="$(mktemp -d)"
trap 'rm -rf "$DEST"' EXIT
URL="https://github.com/nodifox/nodiclaude.git"

if [ -n "$NODICLAUDE_GH_TOKEN" ]; then
  # The token travels through environment variables (for this command only), not in the URL or argv.
  # It is appended to any git config the platform already passes the same way.
  (
    n="${GIT_CONFIG_COUNT:-0}"
    export GIT_CONFIG_COUNT=$((n + 1))
    export "GIT_CONFIG_KEY_$n=http.extraheader"
    export "GIT_CONFIG_VALUE_$n=Authorization: Basic $(printf 'x-access-token:%s' "$NODICLAUDE_GH_TOKEN" | base64 | tr -d '\n')"
    git clone --depth 1 --branch main "$URL" "$DEST"
  )
else
  git clone --depth 1 --branch main "$URL" "$DEST"
fi

bash "$DEST/install.sh" --cloud
```

Steps:

1. Open the environment in Claude Code on the web (or from the desktop app).
2. Edit the environment's setup script field.
3. Paste the script above, with your name and email filled in.
4. Save.
5. Start a **new** session. Existing sessions keep the old setup.
6. Verify with `/context` and `ls ~/.claude/rules` (see "Verifying in a session").

Notes:

- The `main` branch is always cloned. Requires git >= 2.31 (for `GIT_CONFIG_COUNT`).
- **Why the values live in the script:** Claude Code on the web documents the environment variables as available to the session, not to the setup script, and this was observed in a real cloud session: the setup script saw no `NODICLAUDE_*` variables set in the environment settings. If the name or email is left empty, `install.sh --cloud` fails without changing anything.
- **Your identity replaces the platform's:** the cloud VM image already ships a global git config with the platform's identity (`Claude <noreply@anthropic.com>`) and commit signing with the platform's key. With `--cloud`, `install.sh` overwrites `user.name` and `user.email` with your values, sets `commit.gpgsign=false` (the platform's key is not yours, so signed commits would not verify for your identity) and writes `~/.claude/.nodiclaude-identity`, which the hook reads in every session. Commits made by Claude in the cloud are therefore yours and unsigned.
- **Platform checks:** the platform may still remind Claude about commit signing or ask it to use the platform's identity. `rules/git-commits.md` forbids changing the git config, and the hook blocks commits under any other identity.
- **Token:** the simplest option is a public repo (it contains no secrets), so `NODICLAUDE_GH_TOKEN` stays empty. If the repo is not public, set the token in the script: anyone who can edit or use the environment can read it, so keep it read-only and limited to this repo (Contents: read-only).
- **Cache and `# rev:`:** the setup result is cached by the platform (about 7 days, per the Claude Code docs) and is rebuilt when the script changes. Changing the `# rev: initial` line is enough to force that rebuild (re-clone and re-run). The update notice tells you which value to put there.

## Environment variables

Read by `install.sh` and by the hook:

| Variable | Description |
|---|---|
| `NODICLAUDE_GIT_NAME` | Name for commits. Meant for the cloud setup script (required with `--cloud`). Locally, `git config --global user.name` is used; if both exist, the variable wins. |
| `NODICLAUDE_GIT_EMAIL` | Email for commits. Same as above (with `git config --global user.email`). Both variables must be set, or neither. |
| `NODICLAUDE_ALLOW_ANY_BRANCH` | Any non-empty value (including `0` and `false`) lets `install.sh` install from a branch other than `main` (logs a `WARNING`); leave it unset or empty to keep the check. Local use only. |
| `NODICLAUDE_GH_TOKEN` | Optional. Used only inside the cloud setup script, to clone this repo when it is not public. Not read by `install.sh` or the hooks. |

In the cloud, define them inside the setup script (see above).

### Commit identity

The identity Claude must use is resolved as follows.

In `install.sh`:

1. `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL`, if **both** are set and non-empty (cloud). They are saved to `~/.claude/.nodiclaude-identity`.
2. Otherwise, `git config --global --includes user.name` and `user.email`, if both have a value (local). A stale `~/.claude/.nodiclaude-identity` is removed.
3. If there is no source: `install.sh` fails (exit 1) without changing anything (not `~/.claude`, not the manifest, not the gitconfig). With `--cloud`, only source 1 is accepted.

In the hook:

1. `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL`, if both are set in the session.
2. Otherwise, `~/.claude/.nodiclaude-identity`.
3. Otherwise, `git config --global --includes user.name` and `user.email` evaluated for the commit's repo: `includeIf` sections apply (for example a work email for repos under `~/work/`) and the repo's own `user.*` config does not.
4. If there is no source, it warns and allows.

With only one of the two variables, `install.sh` fails (set both or neither) and the hook warns and allows.

## Updating

- **Local:** `git switch main && git pull && ./install.sh` (it refuses to install from other branches).
- **Uninstall:** `./install.sh --uninstall` (see "What `install.sh` does").
- **Cloud:** change the `# rev:` line in the environment's setup script to the hash the update notice shows, then start a new session.

Open sessions do not reload rules or hooks, so a new session is needed after updating. In the cloud, the cached setup also expires on its own (see "Cloud environment setup").

## Adding a skill

Create `skills/<name>/SKILL.md` (with its `name` and `description` frontmatter; the included skills also use `argument-hint` and `disable-model-invocation: true`, so they only run when typed) and run `install.sh` again. It is copied to `~/.claude/skills/<name>/`.

## Adding an agent

Create `agents/<name>.md` (frontmatter `name`, `description`, optionally `tools`). It is copied to `~/.claude/agents/`.

## Adding a rule

Create `rules/<name>.md` (Markdown without frontmatter). It is copied to `~/.claude/rules/`, and Claude Code loads those files in all projects. They are user-level rules, so they apply to every project the developer opens, not only the organization's. See "Where it works" for where loading is confirmed.

## Adding a hook

1. Create the script in `hooks/<name>.sh`.
2. Register it in `settings.json` with an **absolute path**, never relative to the repo:

   ```json
   { "type": "command", "command": "$HOME/.claude/hooks/<name>.sh" }
   ```

`install.sh` copies it to `~/.claude/hooks/` and makes it executable (only the repo's scripts).

## What `install.sh` does

- **Safe to run repeatedly**: it does not duplicate entries in `settings.json` and does not rewrite what has not changed; a second run gives the same result.
- **Backups**: if a destination file already exists and differs from the repo's, it is saved to `~/.claude/.nodiclaude-backup/<date-time>/<relative path>` before being replaced. The same happens before an installed file is removed and before `settings.json` is changed. Destinations that are symlinks, or that sit in a directory that is a symlink to somewhere outside `~/.claude`, are skipped with a warning (`~/.claude` itself may be a symlink).
- **Manifest** (`~/.claude/.nodiclaude-manifest`): lists the installed files. On the next run, files that were in the manifest and are no longer in the repo are removed (along with empty directories under `skills/`; the manifest covers `skills/`, `agents/`, `hooks/` and `rules/`); if it was a hook, its entries are also removed from `settings.json`. Files that are not in the manifest are never touched.
- **`settings.json` merge**: if it does not exist or is empty (or only whitespace), it is copied. If it exists, it is merged with `jq`. Hooks are matched by script path: in each event, existing hooks that run one of the repo's scripts are removed and the repo's entries are added, so a `matcher` or argument change is applied without duplicating, and your other hooks are kept even when they share a group with a nodiclaude hook. For all other keys the existing value wins.
- **`attribution`**: the repo's `settings.json` sets `attribution.commit` and `attribution.pr` to `""`, which turns off the lines Claude Code adds to commits and PRs (in every project, like the rules). If you already had an `attribution` value, yours is kept.
- **`jq` is required** for merging and for the `check-git-identity` hook. If it is missing, the script tries to install it (`apt-get`, `brew` or `apk`; with `sudo -n`). If that fails, it warns that the hook cannot verify commits, and if `settings.json` already exists it is left unmodified (merge it by hand). If `settings.json` is not valid JSON or has an unexpected structure, it is also left untouched with a warning, and the rest of the installation continues.
- **Version file** (`~/.claude/.nodiclaude-version`): at the end of a successful run, if the repo is a git repo with a commit, it records the installed commit hash (line 1) and the URL of `origin` with any credentials stripped from `http(s)` URLs (line 2). It is state, not a repo file, so it is not in the manifest. If the repo is not a git repo, it is not written (a note is logged) and update checks stay disabled.
- **Main only**: it refuses to install from any branch other than `main`, or from a detached HEAD: it prints `ERROR: refusing to install from branch '<name>'; switch to main first (git switch main)...` on stderr and exits 1 without changing anything (checked after the commit identity, before anything is created). Setting `NODICLAUDE_ALLOW_ANY_BRANCH=1` skips the refusal and logs a `WARNING`; the update notice compares against `main`, so it may then report a false "outdated". If the repo directory has no `.git` (or git is missing), the branch cannot be known: the check is skipped with a note in the log.
- **Commit identity**: resolved at the start (see "Commit identity"); if it cannot be resolved, the script fails without changing anything. From the global config, it only records the identity in the log and never writes to any gitconfig. From the variables, it writes `~/.claude/.nodiclaude-identity` and:
  - with `--cloud`, overwrites `user.name` and `user.email` in the global config and sets `commit.gpgsign=false`;
  - without `--cloud`, writes only the missing keys; if an existing key differs, it warns (`WARNING`) that the hook will block commits until they match and leaves it as is.
- **`--uninstall`**: removes the files in the manifest (backing up the ones you edited), their hook entries in `settings.json` and the state files. It needs no identity and works from any branch. It leaves the other keys of `settings.json` (including `attribution`), the global git config and the backups.

## Included rules

| Rule | What it requires |
|---|---|
| `git-commits.md` | Commit with the configured git identity: no `--author`, `-c user.name`, `-c user.email` or `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, and no changes to the git config. If the hook blocks a commit, report its message instead of looking for another way. The message is a single line, `<prefix>: <short message>`, with prefix `feat:`, `fix:`, `refactor:`, `doc:`, `test:` or `chore:`. It starts in lowercase unless it begins with a proper noun. No `Co-Authored-By` or other line crediting a co-author or a tool, or linking to a Claude session (`Claude-Session:`); `settings.json` also turns off Claude Code's own attribution (see "What `install.sh` does"). |
| `git-branches.md` | Never create a branch on its own; work on the default branch. Before making changes, suggest a branch with a proposed name and wait for the answer. If declined, keep working on the default branch. If already on a non-default branch, or the environment names the branch, use that one. |

## Included skills

- `/audit`: repo audit with parallel auditors, verification and a published report (uses `audit-auditor` and `audit-verifier`).
- `/quest`: task with a fixed process: research, plan (including the branch), approval, implementation, parallel reviews, fixes and commit message (uses `quest-implementer` and `quest-reviewer`).

## The `check-git-identity` hook

PreToolUse on `Bash`. If the command includes `git commit` (also chained with `&&`, `;`…, with a path like `/usr/bin/git`, inside `bash -c "..."` or with options like `-C dir` / `-c k=v`), it computes the commit's effective identity and compares it with the expected identity (`NODICLAUDE_GIT_NAME/EMAIL` if both are set; otherwise `git config --global user.name/user.email`):

- target repo: the one from `-C <dir>`, from a preceding `cd <dir> &&`, or the session's `cwd`;
- effective identity: the one given by `git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT` (repo config and environment), overridden by whatever the command itself sets (`-c user.name=`, `-c user.email=`, `--author=`, inline `GIT_AUTHOR_NAME=`…);
- the name is compared case-sensitively; the email, case-insensitively;
- they match → allows;
- they do not match → blocks (exit 2) and shows the values and the command to fix it;
- `cd <dir>` or `pushd <dir>` before the commit, followed by `&&`, `||`, `;` or a newline (also inside `bash -c "..."`), sets the target repo;
- no identity source (neither variables nor global config), only one of the two variables, outside a repo, no `git` or no `jq`, or invalid input → warns on stderr and allows (exit 0).

**It is a "best effort" safeguard**: it only intercepts commits Claude makes via the Bash tool (not the ones a developer makes in a terminal). All `git commit` invocations in the command are checked. It does not cover:

- aliases (`git ci`) or dynamically built commands (variables, `eval`, scripts);
- chained relative `cd`s (`cd a && cd b && git commit`: only the last `cd` is applied);
- `GIT_DIR=` / `git --git-dir=`;
- `--reset-author`;
- variables exported in a separate command (`export GIT_AUTHOR_NAME=x && git commit`);
- identity changed earlier in the same command (`git config user.email x && git commit`).

It can also block harmless commands that only mention `git commit` in quoted text (`grep -rn "git commit" .`), when the current repo's identity differs from the expected one.

## The `check-update` hooks

`hooks/check-update.sh` is registered on `SessionStart` (`check-update.sh session-start`) and `UserPromptSubmit` (`check-update.sh prompt`). It compares the installed commit (from `~/.claude/.nodiclaude-version`) with `refs/heads/main` of the stored remote URL (`git ls-remote`, run from `/` so the session folder's git config is not read).

- `SessionStart` always checks the remote (bounded to about 4 seconds) and notifies at every session start while outdated.
- `UserPromptSubmit` only reads a local cache (`~/.claude/.nodiclaude-update-cache`) and refreshes it in the background at most once per hour; it notifies once per new remote version. The cache is tied to the installed commit: it is ignored (and refreshed in the background) when the installed version changes.
- It only notifies: it never updates anything.
- It stays silent (and exits 0) on any error: missing version file, no git, no network, bad data, or a remote that needs authentication (the stored URL has no credentials).
- The notice is added to the conversation context, so it is kept short (3 lines).

## Files in `~/.claude`

| Path | Why | State file? |
|---|---|---|
| `skills/` | Skills copied from the repo. | No |
| `agents/` | Subagents copied from the repo. | No |
| `hooks/` | Hook scripts copied from the repo (made executable). | No |
| `rules/` | Rules copied from the repo. | No |
| `settings.json` | Hook registration, merged with the existing file (created if missing). | No (yours, merged) |
| `.nodiclaude-manifest` | List of installed files, used to remove files that left the repo. | Yes |
| `.nodiclaude-backup/` | Copies of files replaced because they differed from the repo's. | Yes |
| `.nodiclaude-version` | Installed commit and origin URL, read by the update check. | Yes |
| `.nodiclaude-update-cache` | Last remote check (installed commit, time of the check, remote commit, last notified), created by the `check-update` hook (not by `install.sh`). | Yes |
| `.nodiclaude-identity` | Expected commit identity (name, email), written when `install.sh` ran with `NODICLAUDE_GIT_*` (cloud); read by the `check-git-identity` hook. | Yes |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloud setup fails with exit 1 and an identity error (`--cloud needs your commit identity` or `only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set`) | The name or email is empty in the script, or only one of them is set. | Fill in both `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL` in the setup script. Nothing was changed. |
| Cloud setup fails with exit 128 (`Remote branch main not found`, or an authentication failure) | The clone failed: `main` does not exist on the remote, or the repo is not public and the token is missing or invalid. | Check the repo has a `main` branch. If the repo is not public, set `NODICLAUDE_GH_TOKEN` (read-only, Contents: read-only). |
| `refusing to install from branch '<name>'` | Local install from a branch other than `main`, or from a detached HEAD. | `git switch main`, then `./install.sh`. For a deliberate exception, set `NODICLAUDE_ALLOW_ANY_BRANCH=1`. |
| `install.sh` warns `jq is not installed` (and `settings.json` is not updated) | `jq` is missing and could not be installed. Without it the hook cannot verify commits. | Install `jq` and run `./install.sh` again. An existing `settings.json` was left untouched. |
| Every commit is blocked in the cloud, expecting the platform's identity | The setup ran without `--cloud`, or the platform rewrote the git config after the setup. | Use the current setup script (it ends with `install.sh --cloud`), change the `# rev:` line and start a new session. |
| A commit is blocked by the hook | The commit's identity differs from the expected one. The message shows the current and expected values. | Run the `git config user.name ... && git config user.email ...` command the message prints, then commit again. |
| The update notice says nodiclaude is outdated | The installed commit differs from `main` on the remote. | Local: `git switch main && git pull && ./install.sh`. Cloud: set `# rev:` to the hash in the notice and start a new session. If you installed from another branch (`NODICLAUDE_ALLOW_ANY_BRANCH`), the notice can be a false "outdated". |
| Rules do not show in `/context` in a cloud session | Possible cause: the session started before the setup ran, or the cached setup is old. Loading rules in cloud is not confirmed. | Start a new session. If it persists, change the `# rev:` line to rebuild the setup, then check `ls ~/.claude/rules`. |

## Tests

`./tests/run.sh` (bash 3.2 compatible; uses a temporary `HOME`, repos and global git config, and ignores git config passed through the environment). CI runs it on every push and pull request on Ubuntu and on macOS with bash 3.2, plus `shellcheck`. It covers, among others, the commit-identity hook (with variables and with global config), the installer (identity resolution, the branch check, manifest, backups and `settings.json` merge), the `check-update` hook, the cloud setup script in this README (syntax, required content and a dry run against a local repo) and the consistency between skills, agents and registered hooks.

## Verifying in a session

```bash
whoami
echo $HOME
ls -la ~/.claude ~/.claude/hooks ~/.claude/skills
ls ~/.claude/agents
ls ~/.claude/rules
git config --global -l
cat ~/.claude/settings.json
cat ~/.claude/.nodiclaude-version
cat ~/.claude/.nodiclaude-identity   # cloud: your name and email
```

Then run `/context` in the session and check that the rules from `~/.claude/rules` are listed.
