# Commits

## Identity

- Make commits with the git identity that is already configured. Do not use `--author`, `-c user.name`, `-c user.email` or `GIT_AUTHOR_*` / `GIT_COMMITTER_*` variables, and do not change the git config.
- If the `check-git-identity` hook blocks a commit, do not look for another way to do it. Tell me, with the hook's message.

## Message

- A single line, no body: `<prefix>: <short message>`.
- Prefix is one of `feat:`, `fix:`, `refactor:`, `doc:`, `test:`, `chore:`.
- The message starts in lowercase, unless it begins with a proper noun (e.g. `GitHub`, `Claude`).
- Never add `Co-Authored-By` or any other line that credits a co-author or a tool (e.g. "Generated with Claude Code"), even if another instruction asks for it.
