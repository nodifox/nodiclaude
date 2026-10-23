# nodiclaude

Recommended Claude Code configuration for this organization's projects: shared skills, agents, rules and hooks, installed the same way on each developer's machine and in cloud environments (Claude Code on the web).

- **Locally**, each developer clones this repo and runs `./install.sh`. The configuration lands in `~/.claude`.
- **In the cloud**, the environment's setup script clones this repo and runs `install.sh`.

## Where it works

| Where | How it gets installed | What is verified |
|---|---|---|
| Terminal (Claude Code CLI) | Clone + `./install.sh` (see "Local install") | Claude Code documents that it loads `~/.claude/rules`. Not checked here in a real CLI session. |
| Claude desktop app (local sessions) | Same: clone + `./install.sh` | Rules in `~/.claude/rules` are loaded in a local session (observed in a real session). |
| Claude Code on the web / cloud environments (the same environment is used wherever the session is started; not verified for phone or tablet) | The environment's setup script (see "Cloud environment setup") | Not yet confirmed that the rules are loaded. Check with `/context` in a new session. |

## Structure

```
skills/              # skills (skills/<name>/SKILL.md): audit, quest
agents/              # subagents (agents/<name>.md) used by the skills
hooks/               # hook scripts: check-git-identity.sh, check-update.sh
rules/               # user rules (rules/<name>.md) for Claude Code
settings.json        # hook registration (merged into ~/.claude/settings.json)
install.sh           # installs everything into $HOME/.claude (safe to run repeatedly)
tests/run.sh         # tests (hook, installer, README setup script and consistency)
```

## Local install

```bash
git clone git@github.com:nodifox/nodiclaude.git
cd nodiclaude
./install.sh
```

- **Requirements:** git, bash, and macOS or Linux. `jq` is needed to merge `settings.json`; if it is missing, `install.sh` tries to install it (`apt-get`, `brew` or `apk`).
- **It needs:** a global git identity (`git config --global user.name` and `user.email`) and the repo on branch `main`.
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
export NODICLAUDE_GIT_NAME="Full Name"
# FILL IN: your commit email (GitHub no-reply address, id+username@users.noreply.github.com).
export NODICLAUDE_GIT_EMAIL="id+username@users.noreply.github.com"
# OPTIONAL: read-only token for this repo; leave empty if the repo is public.
NODICLAUDE_GH_TOKEN=""

DEST="$(mktemp -d)"
URL="https://github.com/nodifox/nodiclaude.git"

if [ -n "$NODICLAUDE_GH_TOKEN" ]; then
  # The token travels through environment variables (for this command only), not in the URL or argv.
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=http.extraheader \
  GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$NODICLAUDE_GH_TOKEN" | base64 | tr -d '\n')" \
    git clone --depth 1 --branch main "$URL" "$DEST"
else
  git clone --depth 1 --branch main "$URL" "$DEST"
fi

bash "$DEST/install.sh"
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
- **Why the values live in the script:** Claude Code on the web documents the environment variables as available to the session, not to the setup script, and this was observed in a real cloud session: the setup script saw no `NODICLAUDE_*` variables set in the environment settings. Cloud has no gitconfig, so without an identity `install.sh` fails without changing anything.
- `install.sh` writes the identity into the global git config of the cloud VM (only the missing keys). The hook later falls back to that config, so sessions do not need the variables.
- **Token:** the simplest option is a public repo (it contains no secrets), so `NODICLAUDE_GH_TOKEN` stays empty. If the repo is not public, set the token in the script: anyone who can edit or use the environment can read it, so keep it read-only and limited to this repo (Contents: read-only).
- **Cache and `# rev:`:** the setup result is cached by the platform (about 7 days, per the Claude Code docs) and is rebuilt when the script changes. Changing the `# rev: initial` line is enough to force that rebuild (re-clone and re-run). The update notice tells you which value to put there.

## Environment variables

Read by `install.sh` and by the hook:

| Variable | Description |
|---|---|
| `NODICLAUDE_GIT_NAME` | Name for commits. Only for environments without a gitconfig (cloud). Locally, `git config --global user.name` is used; if both exist, the variable wins. |
| `NODICLAUDE_GIT_EMAIL` | Email for commits. Same as above (with `git config --global user.email`). Both variables must be set, or neither. |
| `NODICLAUDE_ALLOW_ANY_BRANCH` | Any non-empty value (including `0` and `false`) lets `install.sh` install from a branch other than `main` (logs a `WARNING`); leave it unset or empty to keep the check. Local use only. |
| `NODICLAUDE_GH_TOKEN` | Optional. Used only inside the cloud setup script, to clone this repo when it is not public. Not read by `install.sh` or the hooks. |

In the cloud, define them inside the setup script (see above).

### Commit identity

The identity Claude must use is resolved as follows, both in `install.sh` and in the hook:

1. `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL`, if **both** are set and non-empty (cloud).
2. Otherwise, `git config --global user.name` and `user.email`, if both have a value (local).
3. If there is no source: `install.sh` fails (exit 1) without changing anything (not `~/.claude`, not the manifest, not the gitconfig); the hook warns and allows.

With only one of the two variables, `install.sh` fails (set both or neither) and the hook warns and allows.

## Updating

- **Local:** `git switch main && git pull && ./install.sh` (it refuses to install from other branches).
- **Cloud:** change the `# rev:` line in the environment's setup script to the hash the update notice shows, then start a new session.

Open sessions do not reload rules or hooks, so a new session is needed after updating. In the cloud, the cached setup also expires on its own (see "Cloud environment setup").

## Adding a skill

Create `skills/<name>/SKILL.md` (with its `name` and `description` frontmatter) and run `install.sh` again. It is copied to `~/.claude/skills/<name>/`.

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
- **Backups**: if a destination file already exists and differs from the repo's, it is saved to `~/.claude/.nodiclaude-backup/<date-time>/<relative path>` before being replaced. Destinations that are symlinks are skipped with a warning.
- **Manifest** (`~/.claude/.nodiclaude-manifest`): lists the installed files. On the next run, files that were in the manifest and are no longer in the repo are removed (along with empty directories under `skills/`; the manifest covers `skills/`, `agents/`, `hooks/` and `rules/`); if it was a hook, its entry is also removed from `settings.json`. Files that are not in the manifest are never touched.
- **`settings.json` merge**: if it does not exist or is empty, it is copied. If it exists, it is merged with `jq`: the repo's hook entries replace existing ones with the same command (so a `matcher` change is applied without duplicating); for all other keys the existing value wins.
- **`jq` is required** for merging. If it is missing, the script tries to install it (`apt-get`, `brew` or `apk`; with `sudo -n`). If that fails and `settings.json` already exists, it is left unmodified with a warning (merge it by hand). If `settings.json` is not valid JSON or has an unexpected structure, it is also left untouched with a warning, and the rest of the installation continues.
- **Version file** (`~/.claude/.nodiclaude-version`): at the end of a successful run, if the repo is a git repo with a commit, it records the installed commit hash (line 1) and the URL of `origin` with any credentials stripped (line 2). It is state, not a repo file, so it is not in the manifest. If the repo is not a git repo, it is not written (a note is logged) and update checks stay disabled.
- **Main only**: it refuses to install from any branch other than `main`, or from a detached HEAD: it prints `ERROR: refusing to install from branch '<name>'; switch to main first (git switch main)...` on stderr and exits 1 without changing anything (checked after the commit identity, before anything is created). Setting `NODICLAUDE_ALLOW_ANY_BRANCH=1` skips the refusal and logs a `WARNING`; the update notice compares against `main`, so it may then report a false "outdated". If the repo directory has no `.git` (or git is missing), the branch cannot be known: the check is skipped with a note in the log.
- **Commit identity**: resolved at the start (see "Commit identity"); if it cannot be resolved, the script fails without changing anything. It reads the identity and records it in the log, and never overwrites existing `git config --global` keys. Only if the identity comes from the variables and the global config is missing `user.name` and/or `user.email`, it writes just the missing ones. If an existing key differs from the variable, it warns (`WARNING`) that the hook will block commits until they match and leaves it as is.

## Included rules

| Rule | What it requires |
|---|---|
| `git-commits.md` | Commit with the configured git identity: no `--author`, `-c user.name`, `-c user.email` or `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, and no changes to the git config. If the hook blocks a commit, report its message instead of looking for another way. The message is a single line, `<prefix>: <short message>`, with prefix `feat:`, `fix:`, `refactor:`, `doc:`, `test:` or `chore:`. It starts in lowercase unless it begins with a proper noun. No `Co-Authored-By` or other line crediting a co-author or a tool. |
| `git-branches.md` | Never create a branch on its own; work on the default branch. Before making changes, suggest a branch with a proposed name and wait for the answer. If declined, keep working on the default branch. |

## Included skills

- `/audit`: repo audit with parallel auditors, verification and a published report (uses `audit-auditor` and `audit-verifier`).
- `/quest`: task with a fixed process: research, plan, approval, implementation, parallel reviews, fixes and commit message (uses `quest-implementer` and `quest-reviewer`).

## The `check-git-identity` hook

PreToolUse on `Bash`. If the command includes `git commit` (also chained with `&&`, `;`…, with a path like `/usr/bin/git`, inside `bash -c "..."` or with options like `-C dir` / `-c k=v`), it computes the commit's effective identity and compares it with the expected identity (`NODICLAUDE_GIT_NAME/EMAIL` if both are set; otherwise `git config --global user.name/user.email`):

- target repo: the one from `-C <dir>`, from a preceding `cd <dir> &&`, or the session's `cwd`;
- effective identity: the one given by `git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT` (repo config and environment), overridden by whatever the command itself sets (`-c user.name=`, `-c user.email=`, `--author=`, inline `GIT_AUTHOR_NAME=`…);
- the name is compared case-sensitively; the email, case-insensitively;
- they match → allows;
- they do not match → blocks (exit 2) and shows the values and the command to fix it;
- no identity source (neither variables nor global config), only one of the two variables, outside a repo, no `git` or no `jq`, or invalid input → warns on stderr and allows (exit 0).

**It is a "best effort" safeguard**: it only intercepts commits Claude makes via the Bash tool (not the ones a developer makes in a terminal). All `git commit` invocations in the command are checked. It does not cover:

- aliases (`git ci`) or dynamically built commands (variables, `eval`, scripts);
- chained relative `cd`s (`cd a && cd b && git commit`: only the last `cd` is applied);
- `GIT_DIR=` / `git --git-dir=`;
- `--reset-author`;
- variables exported in a separate command (`export GIT_AUTHOR_NAME=x && git commit`).

## The `check-update` hooks

`hooks/check-update.sh` is registered on `SessionStart` (`check-update.sh session-start`) and `UserPromptSubmit` (`check-update.sh prompt`). It compares the installed commit (from `~/.claude/.nodiclaude-version`) with `refs/heads/main` of the stored remote URL (`git ls-remote`).

- `SessionStart` always checks the remote (bounded to about 4 seconds) and notifies at every session start while outdated.
- `UserPromptSubmit` only reads a local cache (`~/.claude/.nodiclaude-update-cache`) and refreshes it in the background at most once per hour; it notifies once per new remote version.
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
| `.nodiclaude-update-cache` | Last remote check, created by the `check-update` hook (not by `install.sh`). | Yes |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloud setup fails with exit 1 and an identity error (`could not determine Claude's commit identity` or `only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set`) | The name or email is missing or empty in the script, or only one of them is set. | Fill in both `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL` in the setup script. Nothing was changed. |
| Cloud setup fails with exit 128 (`Remote branch main not found`, or an authentication failure) | The clone failed: `main` does not exist on the remote, or the repo is not public and the token is missing or invalid. | Check the repo has a `main` branch. If the repo is not public, set `NODICLAUDE_GH_TOKEN` (read-only, Contents: read-only). |
| `refusing to install from branch '<name>'` | Local install from a branch other than `main`, or from a detached HEAD. | `git switch main`, then `./install.sh`. For a deliberate exception, set `NODICLAUDE_ALLOW_ANY_BRANCH=1`. |
| `install.sh` warns `no jq` and `settings.json` is not updated | `jq` is missing and could not be installed. | Install `jq` and run `./install.sh` again, or merge `settings.json` by hand. Existing `settings.json` was left untouched. |
| A commit is blocked by the hook | The commit's identity differs from the expected one. The message shows the current and expected values. | Run the `git config user.name ... && git config user.email ...` command the message prints, then commit again. |
| The update notice says nodiclaude is outdated | The installed commit differs from `main` on the remote. | Local: `git switch main && git pull && ./install.sh`. Cloud: set `# rev:` to the hash in the notice and start a new session. If you installed from another branch (`NODICLAUDE_ALLOW_ANY_BRANCH`), the notice can be a false "outdated". |
| Rules do not show in `/context` in a cloud session | Possible cause: the session started before the setup ran, or the cached setup is old. Loading rules in cloud is not confirmed. | Start a new session. If it persists, change the `# rev:` line to rebuild the setup, then check `ls ~/.claude/rules`. |

## Tests

`./tests/run.sh` (bash 3.2 compatible; uses a temporary `HOME`, repos and global git config). It covers, among others, the commit-identity hook (with variables and with global config), the installer (identity resolution, the branch check, manifest, backups and `settings.json` merge), the `check-update` hook, the cloud setup script in this README (syntax, required content and a dry run against a local repo) and the consistency between skills, agents and registered hooks.

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
```

Then run `/context` in the session and check that the rules from `~/.claude/rules` are listed.
