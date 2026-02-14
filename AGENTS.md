# AGENTS.md

## Core Workflow

1. Keep changes small, focused, and easy to review.
2. Update docs when behavior or workflow changes.
3. Do not rewrite shared history unless explicitly requested.
4. Validate changes locally when practical.

## Commit Ownership

1. The repository owner creates and GPG-signs commits.
2. Agents must not run `git commit` unless explicitly asked.
3. If asked for a message, base it on currently staged changes.
4. If staged and unstaged differ, state that the message is staged-only.

## Commit Message Rules

1. Headline format: `<type>(<scope>): <Headline>`.
2. Use a prefix and capitalize the first character of the headline.
3. Keep headline length at 72 characters maximum.
4. Write the body as bullet points.
5. Write each bullet as a full sentence explaining what changed and why.

## Style Rules

1. Keep code and config lines at 80 characters maximum.

## Docker and Compose

1. Prefer reproducible images by pinning key runtime/tool versions.
2. Minimize packages and run as non-root unless root is required.
3. Keep configuration portable; avoid user-specific absolute host paths.
4. Keep secrets in runtime environment or secret managers, never hardcoded.
5. For interactive shells, do not use auto-restart policies.
