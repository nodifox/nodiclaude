---
name: quest
description: Run a task through a fixed process - research, plan, user approval, implementation, parallel reviews, fixes, final check, commit message.
argument-hint: <task description>
disable-model-invocation: true
---

# Quest

Task: $ARGUMENTS

Follow these steps in order. Do not skip the approval step.

## 1. Research

Understand the current state of the repository before planning:

- Read the repository's `CLAUDE.md` (root or `.claude/CLAUDE.md`), any `.claude/rules/` files and the `README`. Their rules, and the user rules in your context, apply to every step.
- Read the files the task touches. For wide searches across many files, use the `Explore` agent and keep only its conclusions.

## 2. Plan

Write a short plan for the user:

- What will change, file by file.
- Which docs (`CLAUDE.md`, `.claude/rules/`) must be updated to record any decision that has to hold in the future.
- Decisions that are the user's to make, with a recommendation for each.
- Branch: if the user's rules ask you to propose a branch before making changes, propose its name here. If you are already on a non-default branch, or the environment names the branch to work on, say that this branch will be used.
- Size: **small** (a few files, low risk) or **large**.

## 3. Approval

Stop and wait for the user to approve the plan, including the branch. If they ask for changes, update the plan and ask again. Do not continue without a clear yes.

## 4. Implement

First create or switch to the approved branch yourself, if it is not the current one.

Launch one `quest-implementer` agent with the approved plan, the repository rules that apply, the branch (already set up; it must not commit or change branches) and what verification to run (build, tests, running the app). Wait for it to finish. Keep its agent name, which applies the fixes later, and the list of files it changed.

If it stops because the plan is wrong or incomplete, update the plan and go back to step 3.

## 5. Review

Launch `quest-reviewer` agents in parallel, each with the approved plan, the list of changed files and a different focus:

- **Correctness**: it works, it builds, nothing is broken, edge cases.
- **Minimalism and rules**: nothing unused, no boilerplate, no unrequested files or options, the repository rules are followed.

For a **small** task, launch a single reviewer that covers both focuses.

## 6. Fix

If the reviewers reported issues, send them to the same `quest-implementer` agent with SendMessage (it keeps its context); if SendMessage is unavailable, launch a new `quest-implementer` with the plan and the findings as context. Leave out findings you judge to be wrong, and tell the user which ones and why. If there were no issues, skip to step 8.

## 7. Final check

Launch one `quest-reviewer` with the fixes and the files they touched, which checks only that each fix is correct. Do not review the whole change again.

## 8. Summary

Tell the user:

- What changed.
- What the reviewers found and what was fixed.
- What was left out or is still pending, and why.

## 9. Commit message

End with a one-line commit message for the changes this quest made, in a fenced code block so the user can copy it:

- One line, at most about 72 characters. If the user's rules in your context define a commit message format (for example `rules/git-commits.md`), follow it. Otherwise follow the repository's style and language (check `git log --oneline`), in imperative mood.
- Describe only this quest's changes, not other uncommitted work in the tree.
- Do not commit: only propose the message.
