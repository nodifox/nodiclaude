# nodiclaude

Recommended Claude Code configuration for this organization's projects: shared skills, agents, rules and hooks, installed the same way on each developer's machine and in cloud environments (Claude Code on the web).

- **Locally**, each developer clones this repo and runs `./install.sh`. The configuration lands in `~/.claude`.
- **In the cloud**, the environment's setup script clones this repo from GitHub and runs `install.sh --cloud`.

## Where it works

| Where | How it gets installed | What is verified |
|---|---|---|
| Terminal (Claude Code CLI) | Clone + `./install.sh` (see "Local install") | Claude Code documents that it loads `~/.claude/rules`. Not checked here in a real CLI session. |
| Claude desktop app (local sessions) | Same: clone + `./install.sh` | Rules in `~/.claude/rules` are loaded in a local session (observed in a real session). |
| Claude Code on the web / cloud environments (the same environment is used wherever the session is started; not verified for phone or tablet) | The environment's setup script clones the repo and runs `install.sh --cloud` (see "Cloud environment setup") | Rules in `~/.claude/rules` are loaded in a cloud session, also in subagents (observed in a real session). |

## Structure

```
skills/              # skills (skills/<name>/SKILL.md): audit, quest
agents/              # subagents (agents/<name>.md) used by the skills
hooks/               # hook scripts: check-git-identity.sh, check-update.sh, check-attribution.sh
rules/               # user rules (rules/<name>.md) for Claude Code
settings.json        # hook registration and attribution settings (merged into ~/.claude/settings.json)
install.sh           # installs everything into $HOME/.claude (safe to run repeatedly); --cloud, --uninstall
tests/run.sh         # tests (hooks, installer, README setup script and consistency)
.github/workflows/   # CI: tests on Ubuntu and macOS (bash 3.2), shellcheck
```

## Local install

```bash
git clone https://github.com/nodifox/nodiclaude.git
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

The setup script clones `nodifox/nodiclaude` from GitHub (`main`) and installs it. Fill in only the lines marked `FILL IN` below.

```bash
#!/usr/bin/env bash
# rev: initial
set -euo pipefail

# FILL IN: your full name, used for Claude's commits.
export NODICLAUDE_GIT_NAME=""
# FILL IN: your commit email (e.g. your GitHub no-reply address, id+username@users.noreply.github.com).
export NODICLAUDE_GIT_EMAIL=""

URL="https://github.com/nodifox/nodiclaude.git"
DEST="$(mktemp -d)"
trap 'rm -rf "$DEST"' EXIT
git clone -q --depth 1 --branch main "$URL" "$DEST"

bash "$DEST/install.sh" --cloud
```

Steps:

1. In Claude Code on the web (or from the desktop app), create a **new** personal environment. A dedicated environment is recommended because the script holds your name and email.
2. Optional, for Verified commits: under Environment variables, add `NODICLAUDE_SIGNING_KEY` with your signing key (see "Verified commits").
3. Paste the script above, with your name and email filled in, into the environment's setup script field, and save.
4. Start a **new** session in that environment with the repo you work on. Existing sessions keep the old setup.
5. Verify with `/context` and `ls ~/.claude/rules` (see "Verifying in a session").

### Security model

The setup script holds no secrets:

- **GitHub access:** the repo is public, so the script clones it over HTTPS with no credentials. The script carries no token. Because the repo content is public, it must never hold secrets (keys, tokens, personal data).
- **The signing key** (optional) lives in the environment's Environment variables as `NODICLAUDE_SIGNING_KEY`. It is stored in plain text in the environment settings, readable by anyone who can edit the environment, and it is present in the session's process environment and in `~/.claude/.nodiclaude-signing-key` (mode 0600). It is not in the setup script, but anything running in the session (including Claude through its shell) can read its value from the environment.

The mitigation is mandatory: use a signing key generated **exclusively** for this tool, never reused anywhere else: a dedicated ed25519 key, registered on GitHub only as a Signing Key, with no authentication access. It cannot push or authenticate, and it can be revoked on GitHub if it leaks.

### Notes

- The script installs the latest commit of `main` on GitHub (a shallow clone into a temporary directory, removed when the script ends). If the clone fails, the script stops before installing anything.
- **Why the name and email live in the script:** Claude Code on the web documents the environment variables as available to the session, not to the setup script, and this was observed in a real cloud session: the setup script saw no `NODICLAUDE_*` variables set in the environment settings. `install.sh --cloud` runs from the setup script, so the name and email must be in the script; if either is left empty, it fails without changing anything. The signing key, in contrast, is read from the session's environment by the `SessionStart` hook (see below), so it can stay out of the script.
- **Your identity replaces the platform's:** the cloud VM image already ships a global git config with the platform's identity (`Claude <noreply@anthropic.com>`) and commit signing with the platform's key. With `--cloud`, `install.sh` overwrites `user.name` and `user.email` with your values and writes `~/.claude/.nodiclaude-identity`, which the hook reads in every session. The platform's key is not yours, so signed commits would not verify for your identity: without a signing key, `commit.gpgsign=false` (commits are yours and unsigned); with one, commits are signed with your own key (see "Verified commits"). Because the platform can rewrite the global git config after the setup script, `--cloud` also generates and registers a `SessionStart` hook (`~/.claude/hooks/nodiclaude-apply-identity.sh`) that, at the start of every session, installs `NODICLAUDE_SIGNING_KEY` from the session's environment if it is set and valid, then re-applies the name, the email and the signing config (SSH signing and the allowed-signers file if `~/.claude/.nodiclaude-signing-key` is readable and `ssh-keygen` is available, otherwise `commit.gpgsign=false`). It is created by `install.sh` itself (it is not a repo file) and `--uninstall` removes it.
- **Platform checks:** the platform may still remind Claude about commit signing or ask it to use the platform's identity. `rules/git-commits.md` forbids changing the git config, and the hook blocks commits under any other identity.
- **Verified commits:** without a signing key, commits made by Claude in the cloud are unsigned, so GitHub does not mark them as verified (the merge or squash commit created by merging the pull request on GitHub is signed by GitHub). To get Verified commits, give the environment an SSH private key:
  1. Generate a **dedicated** key with no passphrase: `ssh-keygen -t ed25519 -N "" -C "nodiclaude signing" -f ~/.ssh/nodiclaude_signing`. Never reuse an authentication key.
  2. On GitHub, add `~/.ssh/nodiclaude_signing.pub` under Settings, SSH and GPG keys, with key type **Signing Key**. The commit email must be a verified email of that account (the no-reply address works).
  3. In the environment settings, add the private key (all lines) as the environment variable `NODICLAUDE_SIGNING_KEY`, then start a new session.

  How it is applied:
  - The setup script does not see the variable, so `install.sh --cloud` sets `commit.gpgsign=false`, removes a stale key file (and the allowed-signers file, unsetting `gpg.ssh.allowedSignersFile` if it points to it) and installs `openssh-client` with `apt-get` if `ssh-keygen` is missing (only a warning if that fails).
  - At session start, the `SessionStart` hook removes carriage returns and surrounding whitespace from the key, validates it with `ssh-keygen -y` and saves it to `~/.claude/.nodiclaude-signing-key` (mode 0600). It then sets `gpg.format=ssh`, `user.signingkey`, `gpg.ssh.program=ssh-keygen` and `commit.gpgsign=true`. It never prints the key.
  - It also writes `~/.claude/.nodiclaude-allowed-signers` (your email and the key's public key) and sets `gpg.ssh.allowedSignersFile` to it, so `git log --show-signature` and `git verify-commit` verify your commits locally inside the session. The Verified badge on GitHub still requires the public key to be registered as a **Signing Key** on GitHub (step 2), which cannot be checked from the container.
  - An invalid value (not a passphrase-less OpenSSH private key) is ignored: the hook writes nothing and leaves an existing key file as is.
  - Pasting the key into the setup script (`export NODICLAUDE_SIGNING_KEY="..."`) is still accepted but not recommended, because it puts the key in the script. `install.sh --cloud` then validates it before changing anything (failing if it is invalid) and installs it itself.
  - Without `--cloud`, `install.sh` ignores the variable with a warning.

  **Verified by the tests** (temporary `HOME`): local `git verify-commit` of a signed commit, with the key from the setup script and from the hook's environment, local verification through the installed allowed-signers file (`git verify-commit` and `git log --show-signature`), and the hook re-applying the config. **Not verified:** the Verified badge on GitHub; in a real cloud session, that the environment variable reaches `SessionStart` hooks.

  To sign with the same key locally (`install.sh` does not do this):

  ```bash
  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/nodiclaude_signing
  git config --global commit.gpgsign true
  ```
- **Cache and `# rev:`:** the setup result is cached by the platform (about 7 days, per the Claude Code docs) and is rebuilt when the script changes. Changing the `# rev: initial` line is enough to force that rebuild (re-run). The update notice tells you which value to put there.

## Environment variables

Read by `install.sh` and by the hook:

| Variable | Description |
|---|---|
| `NODICLAUDE_GIT_NAME` | Name for commits. Meant for the cloud setup script (required with `--cloud`). Locally, `git config --global user.name` is used; if both exist, the variable wins. |
| `NODICLAUDE_GIT_EMAIL` | Email for commits. Same as above (with `git config --global user.email`). Both variables must be set, or neither. |
| `NODICLAUDE_ALLOW_ANY_BRANCH` | Any non-empty value (including `0` and `false`) lets `install.sh` install from a branch other than `main` (logs a `WARNING`); leave it unset or empty to keep the check. Local use only. |
| `NODICLAUDE_SIGNING_KEY` | Optional, cloud only. An OpenSSH private key (multi-line, no passphrase) used to sign Claude's commits; empty means unsigned commits. Set it as an environment variable of the cloud environment: the `SessionStart` hook generated by `--cloud` reads it at session start. Also accepted from the setup script with `--cloud` (not recommended: it puts the key in the script). Ignored by `install.sh` with a warning without `--cloud`. See "Verified commits". |

In the cloud, define `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL` inside the setup script (the setup script cannot read the environment's variables) and `NODICLAUDE_SIGNING_KEY` under the environment's Environment variables (see "Cloud environment setup").

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
  - with `--cloud`, overwrites `user.name` and `user.email` in the global config and sets `commit.gpgsign=false`, or, if `NODICLAUDE_SIGNING_KEY` is set in the setup script (validated before anything changes), installs the key to `~/.claude/.nodiclaude-signing-key`, configures SSH signing (`gpg.format`, `user.signingkey`, `gpg.ssh.program`, `commit.gpgsign=true`) and writes `~/.claude/.nodiclaude-allowed-signers` with `gpg.ssh.allowedSignersFile` for local verification; without a key it removes a stale key file and allowed-signers file (unsetting `gpg.ssh.allowedSignersFile` only if it points to it) and installs `openssh-client` if `ssh-keygen` is missing (a warning if it cannot). It also generates the `SessionStart` hook that installs the key from the environment's variables at session start (see "Verified commits");
  - without `--cloud`, writes only the missing keys; if an existing key differs, it warns (`WARNING`) that the hook will block commits until they match and leaves it as is.
- **`--uninstall`**: removes the files in the manifest (backing up the ones you edited), their hook entries in `settings.json` and the state files (including the signing key and the allowed-signers file). It needs no identity and works from any branch. It leaves the other keys of `settings.json` (including `attribution`), the global git config and the backups.

## Included rules

| Rule | What it requires |
|---|---|
| `git-commits.md` | Commit with the configured git identity: no `--author`, `-c user.name`, `-c user.email` or `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, and no changes to the git config. If the hook blocks a commit, report its message instead of looking for another way. The message is a single line, `<prefix>: <short message>`, with prefix `feat:`, `fix:`, `refactor:`, `doc:`, `test:` or `chore:`. It starts in lowercase unless it begins with a proper noun. No `Co-Authored-By` or other line crediting a co-author or a tool, or linking to a Claude session (`Claude-Session:`); `settings.json` also turns off Claude Code's own attribution (see "What `install.sh` does"). The same applies to pull request titles and descriptions, comments and reviews: if a tool adds a "Generated by Claude Code" footer on its own, Claude edits it out right afterwards. The `check-attribution` hook reminds Claude to do it after each GitHub write (see "The `check-attribution` hook"). |
| `git-branches.md` | Never create a branch on its own; work on the default branch. Before making changes, suggest a branch with a proposed name and wait for the answer. If declined, keep working on the default branch. If already on a non-default branch, or the environment names the branch, use that one. |

## Included skills

- `/audit`: repo audit with parallel auditors, verification and a published report (uses `audit-auditor` and `audit-verifier`).
- `/quest`: task with a fixed process: research, plan (including the branch), approval, implementation, parallel reviews, fixes and commit message (uses `quest-implementer` and `quest-reviewer`).

## The `check-git-identity` hook

PreToolUse on `Bash`. It reads the command the way the shell would split it (quotes, escapes, comments, heredocs, `$(...)`, backticks, subshells, `bash -c '...'`) and checks every `git commit` that actually runs as a command (also chained with `&&`, `;`, newlines…, with a path like `/usr/bin/git`, after wrappers such as `env`, `sudo`, `timeout` or `if`, or with options like `-C dir` / `-c k=v`). For each one it computes the commit's effective identity and compares it with the expected identity (see "Commit identity"):

- target repo: the session's `cwd`, changed by earlier `cd <dir>` / `pushd <dir>` in the same command (a `cd` inside `( ... )` or `$( ... )` does not leak out), then by `-C <dir>`, `--git-dir` / `--work-tree` or `GIT_DIR=` / `GIT_WORK_TREE=`;
- effective identity: the one given by `git var GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT` (repo config and environment), overridden by whatever the command itself sets (`-c user.name=`, `-c user.email=`, `--author=`, inline or exported `GIT_AUTHOR_NAME=`…);
- the name is compared case-sensitively; the email, case-insensitively;
- they match → allows;
- they do not match → blocks (exit 2) and shows the values and the command to fix it;
- no identity source (neither variables nor global config), only one of the two variables, outside a repo, no `git` or no `jq`, or invalid input → warns on stderr and allows (exit 0).

Text that only mentions `git commit` is never checked: an argument (`grep -rn "git commit" .`, `echo git commit`, `gh pr create --body '...'`), a heredoc body or a comment.

**It is a "best effort" safeguard**: it only intercepts commits Claude makes via the Bash tool (not the ones a developer makes in a terminal). It does not cover:

- aliases (`git ci`) or dynamically built commands (variables such as `cd "$dir"`, `eval`, scripts);
- commits run by other programs (`xargs git commit`, `find -exec`, a script fed to a shell through a heredoc: `bash <<EOF`);
- `--reset-author`;
- identity changed earlier in the same command (`git config user.email x && git commit`).

## The `check-update` hooks

`hooks/check-update.sh` is registered on `SessionStart` (`check-update.sh session-start`) and `UserPromptSubmit` (`check-update.sh prompt`). It compares the installed commit (from `~/.claude/.nodiclaude-version`) with `refs/heads/main` of the stored remote URL (`git ls-remote`, run from `/` so the session folder's git config is not read).

- `SessionStart` always checks the remote (bounded to about 4 seconds) and notifies at every session start while outdated.
- `UserPromptSubmit` only reads a local cache (`~/.claude/.nodiclaude-update-cache`) and refreshes it in the background at most once per hour; it notifies once per new remote version. The cache is tied to the installed commit: it is ignored (and refreshed in the background) when the installed version changes.
- It only notifies: it never updates anything.
- It stays silent (and exits 0) on any error: missing version file, no git, no network, bad data, or a remote that needs authentication (the stored URL has no credentials).
- The notice is added to the conversation context, so it is kept short (3 lines).

## The `check-attribution` hook

In Claude Code cloud sessions, the GitHub MCP server can append a `---` line and `_Generated by [Claude Code](https://claude.ai/code/session_...)_` to pull request descriptions and comments, server-side, even when the text Claude sent had none. The `attribution` settings in `settings.json` only cover Claude Code's own attribution, and `rules/git-commits.md` (edit it out right afterwards and read it back) depends on Claude remembering it.

`hooks/check-attribution.sh` is registered on `PostToolUse` for the GitHub MCP tools that publish text: `create_pull_request`, `update_pull_request`, `add_issue_comment`, `update_issue_comment`, `add_reply_to_pull_request_comment`, `add_comment_to_pending_review`, `pull_request_review_write` and `issue_write` (matcher `^mcp__github__(...)$`, anchored because Claude Code tests a matcher with regex characters as an unanchored regular expression, which would otherwise also match e.g. `update_pull_request_branch`). After each of these calls it adds a short reminder to Claude's context: read the text back, remove any "Generated by Claude Code" or Claude session line (and the `---` before it), and read it back again to confirm. It ignores its input, needs no `jq` and always exits 0.

Limits:

- It cannot remove the footer itself: hooks have no access to MCP tools, so Claude still does the edit.
- The footer is visible on GitHub for the few seconds until Claude edits it.
- Email notifications for comments are sent with the original text, footer included; editing the comment does not change them.

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
| `.nodiclaude-signing-key` | Private SSH key (mode 0600) for signing commits, written at session start by the identity hook (`nodiclaude-apply-identity.sh`) when `NODICLAUDE_SIGNING_KEY` is an environment variable of the cloud environment, or by `install.sh --cloud` when the setup script sets it; used by git. | Yes |
| `.nodiclaude-allowed-signers` | Your email and the signing key's public key, written next to `.nodiclaude-signing-key` (by the identity hook or `install.sh --cloud`) and set as `gpg.ssh.allowedSignersFile`, so git verifies signatures locally. | Yes |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Cloud setup fails with exit 1 and an identity error (`--cloud needs your commit identity` or `only one of NODICLAUDE_GIT_NAME / NODICLAUDE_GIT_EMAIL is set`) | The name or email is empty in the script, or only one of them is set. | Fill in both `NODICLAUDE_GIT_NAME` and `NODICLAUDE_GIT_EMAIL` in the setup script. Nothing was changed. |
| Cloud setup fails with exit 128 and a `git clone` error | The environment cannot reach github.com, the repo has no `main` branch, or the repo is no longer public. Nothing is installed. | Check the environment's network access to github.com and that `https://github.com/nodifox/nodiclaude` is public with a `main` branch, then start a new session. |
| Cloud commits are unsigned although `NODICLAUDE_SIGNING_KEY` is set in the environment | The value is not a valid passphrase-less OpenSSH private key (the hook then writes nothing), `ssh-keygen` is missing in the session (`install.sh --cloud` warns if it could not install `openssh-client`), or the session started before the variable was added. | Paste the whole private key (including the BEGIN/END lines) and start a new session. If `ssh-keygen` is missing, install `openssh-client` from the setup script. |
| `refusing to install from branch '<name>'` | Local install from a branch other than `main`, or from a detached HEAD. | `git switch main`, then `./install.sh`. For a deliberate exception, set `NODICLAUDE_ALLOW_ANY_BRANCH=1`. |
| `install.sh` warns `jq is not installed` (and `settings.json` is not updated) | `jq` is missing and could not be installed. Without it the hook cannot verify commits. | Install `jq` and run `./install.sh` again. An existing `settings.json` was left untouched. |
| Every commit is blocked in the cloud, expecting the platform's identity | The setup ran without `--cloud`, or the platform rewrote the git config after the setup and the identity hook (`nodiclaude-apply-identity.sh`) is missing. | Use the current setup script (it ends with `install.sh --cloud`), change the `# rev:` line and start a new session. |
| A commit is blocked by the hook | The commit's identity differs from the expected one. The message shows the current and expected values. | Run the `git config user.name ... && git config user.email ...` command the message prints, then commit again. |
| The update notice says nodiclaude is outdated | The installed commit differs from `main` on the remote. | Local: `git switch main && git pull && ./install.sh`. Cloud: set `# rev:` to the hash in the notice and start a new session. If you installed from another branch (`NODICLAUDE_ALLOW_ANY_BRANCH`), the notice can be a false "outdated". |
| Rules do not show in `/context` in a cloud session | Possible cause: the session started before the setup ran, or the cached setup is old. Loading rules in cloud is not confirmed. | Start a new session. If it persists, change the `# rev:` line to rebuild the setup, then check `ls ~/.claude/rules`. |

## Tests

`./tests/run.sh` (bash 3.2 compatible; uses a temporary `HOME`, repos and global git config, and ignores git config passed through the environment). CI runs it on every push and pull request on Ubuntu and on macOS with bash 3.2, plus `shellcheck`. It covers, among others, the commit-identity hook (with variables and with global config), the installer (identity resolution, the branch check, manifest, backups and `settings.json` merge), the `check-update` and `check-attribution` hooks (including the `PostToolUse` matcher, registration and removal), the cloud setup script in this README (syntax, required content, no secrets, and dry runs cloning a local repo in place of GitHub, including a failed clone), the cloud signing key (from the setup script and from the identity hook's environment) and the consistency between skills, agents and registered hooks.

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
