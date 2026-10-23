---
name: audit
description: Audit the current state of the repository - errors, risks, improvements and what is done well - with parallel auditors, a verification pass and a published report.
argument-hint: [optional focus or path]
disable-model-invocation: true
---

# Audit

Extra focus from the user (may be empty): $ARGUMENTS

The audit is read-only. No agent edits files, deletes data (including Docker containers and volumes) or changes configuration. Building, type checking, linting, running tests and running the app to observe it are allowed.

Follow these steps in order.

## 1. Context

- Read the repository's `CLAUDE.md` (root or `.claude/CLAUDE.md`), any `.claude/rules/` files and the `README`. Their rules are part of the audit.
- List the repository structure so you can tell each auditor where things are.

## 2. Audit

Launch five `audit-auditor` agents in parallel, each with one area, the repository rules and the extra focus (if any):

- **Security**: credentials and secrets, permissions, tenant or user isolation, injection, what each app exposes, unsafe defaults.
- **Correctness**: bugs, edge cases, concurrency, error handling. Build, check and run what can be run to confirm.
- **Architecture and data**: boundaries between apps, clients and shared packages, data model, migrations, coupling, readiness for the target deployment.
- **Tooling and local environment**: package manager, build pipeline, compiler and linter config, local services, environment files; whether a new developer can set everything up by following the README.
- **Docs and rules**: docs match the code, repository rules are followed, unused code, files or dependencies, boilerplate.

## 3. Consolidate

Merge the five reports. Remove duplicates, keeping the best-supported version of each finding.

## 4. Verify

Launch one `audit-verifier` agent with every finding of severity high or medium. It confirms or rejects each one against the code. Drop the rejected findings from the main list and keep them, with the reason, for the report.

## 5. Report

Load the `artifact-design` skill, then publish the report as an Artifact, written in the language the user is using in the conversation. Sections, in this order:

1. **Summary**: overall state in a few lines and the counts per severity.
2. **What is done well**: concrete, backed by files; not filler.
3. **Problems**, most severe first: severity, area, file and line, what goes wrong (a concrete scenario), suggested fix.
4. **Improvements**: worthwhile changes that are not problems.
5. **Discarded findings**: what the verifier rejected and why.

If no Artifact tool is available, print the report in the chat instead.

Then tell the user in a few lines: the link, the counts per severity and the three findings that matter most. Do not fix anything unless the user asks.
