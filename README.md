# nodiclaude

Recommended Claude Code configuration for this organization's projects: shared skills, agents, rules and hooks, installed the same way on each developer's machine and in cloud environments (Claude Code on the web).

- **Locally**, each developer runs `./install.sh` and gets the configuration in `~/.claude`.
- **In the cloud**, the environment's setup script clones this repo and runs `install.sh`.

## Structure

```
skills/              # skills (skills/<name>/SKILL.md): audit, quest
agents/              # subagents (agents/<name>.md) used by the skills
hooks/               # hook scripts: check-git-identity.sh, check-update.sh
rules/               # user rules (rules/<name>.md) for Claude Code
settings.json        # hook registration (merged into ~/.claude/settings.json)
install.sh           # installs everything into $HOME/.claude (safe to run repeatedly)
tests/run.sh         # tests (hook, installer and consistency)
```

## Cloud environment setup

Paste this into the environment's setup script and fill in the values at the top. `GITHUB_OWNER` is the organization that owns this repo.

```bash
#!/usr/bin/env bash
# rev: initial
set -euo pipefail

# Commit identity for this environment. The setup script does not receive the
# variables from the environment settings page, so define them here.
export NODICLAUDE_GIT_NAME="Full Name"
export NODICLAUDE_GIT_EMAIL="id+username@users.noreply.github.com"

# Only needed if this repo is not public: fine-grained token, read-only on the repo.
NODICLAUDE_GH_TOKEN=""

GITHUB_OWNER="nodifox"
REPO="nodiclaude"
DEST="$(mktemp -d)"
URL="https://github.com/${GITHUB_OWNER}/${REPO}.git"

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

- The `main` branch is always cloned. Requires git >= 2.31 (for `GIT_CONFIG_COUNT`).
- **Why the values live in the script:** Claude Code on the web documents the environment variables as available to the session, not to the setup script, and a diagnostic run confirmed that `NODICLAUDE_*` variables set in the environment settings do not reach it. Cloud has no gitconfig, so without an identity `install.sh` fails without changing anything.
- `install.sh` writes the identity into the global git config of the cloud VM (only the missing keys). The hook later falls back to that config, so sessions do not need the variables.
- **Token:** the simplest option is a public repo (it contains no secrets), so `NODICLAUDE_GH_TOKEN` stays empty. If the repo is not public, set the token in the script: anyone who can edit or use the environment can read it, so keep it read-only and limited to this repo (Contents: read-only).
- The setup result is cached by the platform (about 7 days) and is rebuilt when the script changes. Changing the `# rev: initial` line is enough to force that rebuild (re-clone and re-run); the update notice tells you which value to put there.

## Local install

`./install.sh` (honors `$HOME`). It uses the developer's own identity from `git config --global user.name` / `user.email`; if they are missing (and there are no `NODICLAUDE_GIT_*` variables), it fails without changing anything. Locally it never modifies the gitconfig.

## Environment variables

Read by `install.sh` and by the hook:

| Variable | Description |
|---|---|
| `NODICLAUDE_GIT_NAME` | Name for commits. Only for environments without a gitconfig (cloud). Locally, `git config --global user.name` is used; if both exist, the variable wins. |
| `NODICLAUDE_GIT_EMAIL` | Email for commits. Same as above (with `git config --global user.email`). Both variables must be set, or neither. |

In the cloud, define them inside the setup script (see above). `NODICLAUDE_GH_TOKEN` is used only by that script, and only if the repo is not public.

### Commit identity

The identity Claude must use is resolved as follows, both in `install.sh` and in the hook:

1. `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL`, if **both** are set and non-empty (cloud).
2. Otherwise, `git config --global user.name` and `user.email`, if both have a value (local).
3. If there is no source: `install.sh` fails (exit 1) without changing anything (not `~/.claude`, not the manifest, not the gitconfig); the hook warns and allows.

With only one of the two variables, `install.sh` fails (set both or neither) and the hook warns and allows.

## Updating

- **Local:** `git pull && ./install.sh`.
- **Cloud:** change the `# rev:` line in the environment's setup script to the hash the update notice shows, then start a new session.

Open sessions do not reload rules or hooks, so a new session is needed after updating. In the cloud, the cached setup expires after about 7 days even if you forget to change `# rev:`.

## Adding a skill

Create `skills/<name>/SKILL.md` (with its `name` and `description` frontmatter) and run `install.sh` again. It is copied to `~/.claude/skills/<name>/`.

## Adding an agent

Create `agents/<name>.md` (frontmatter `name`, `description`, optionally `tools`). It is copied to `~/.claude/agents/`.

## Adding a rule

Create `rules/<name>.md` (Markdown without frontmatter). It is copied to `~/.claude/rules/`, and Claude Code loads those files in all projects. They are user-level rules, so they apply to every project the developer opens, not only the organization's. Whether they are loaded in Claude Code on the web or in the desktop app is not confirmed by the documentation: check with `/context` in a session. Included: `git-commits.md` (commit identity and message format) and `git-branches.md` (no branches on its own; suggests one before making changes).

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
- **Commit identity**: resolved at the start (see "Commit identity"); if it cannot be resolved, the script fails without changing anything. It reads the identity and records it in the log, and never overwrites existing `git config --global` keys. Only if the identity comes from the variables and the global config is missing `user.name` and/or `user.email`, it writes just the missing ones. If an existing key differs from the variable, it warns (`WARNING`) that the hook will block commits until they match and leaves it as is.

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

## Tests

`./tests/run.sh` (bash 3.2 compatible; uses a temporary `HOME`, repos and global git config). It covers the hook (with variables and with global config), the installer (including identity resolution) and the consistency between skills, agents and registered hooks.

## Verifying in a session

```bash
whoami
echo $HOME
ls -la ~/.claude ~/.claude/hooks ~/.claude/skills
ls ~/.claude/agents
ls ~/.claude/rules
git config --global -l
cat ~/.claude/settings.json
```
