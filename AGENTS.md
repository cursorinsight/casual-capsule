# AGENTS.md

## Workflow

1. Keep changes small, focused, and easy to review.
2. Update docs when behavior or workflow changes.
3. Do not rewrite shared history unless asked.
4. Validate locally when practical.
5. When adding shell flags or arg parsing, test empty-argument cases.

## Git

### Commit ownership

1. Repo owner creates and GPG-signs commits.
2. Do not run `git commit` unless explicitly asked.
3. If asked for commit message, base it on staged changes.
4. If staged and unstaged differ, say message is staged-only.

### Commit messages

1. Headline format: `<type>(<scope>): <Headline>`.
2. Capitalize headline.
3. Keep headline at 68 chars max.
4. Keep all commit message lines at 72 chars max.
5. Use bullet-list body, start items with `*`.
6. Each bullet must be full sentence explaining what changed and why.
7. Use imperative style.

### Attribution

Every AI-assisted commit needs:

```text
Assisted-by: AGENT_NAME:MODEL_VERSION
```

- `AGENT_NAME`: AI tool or framework
- `MODEL_VERSION`: exact model identifier

Example:

```text
Assisted-by: Copilot:claude-sonnet-4.6
```

## Style

1. Keep code and config lines at 80 chars max.
2. Keep shell scripts Bash 3.2+ unless file explicitly needs newer.

## Docker and Compose

1. Pin key runtime and tool versions.
2. Minimize packages. Run non-root unless root is required.
3. Keep config portable. Avoid user-specific absolute host paths.
4. Never hardcode secrets.
5. Interactive shells: no auto-restart.
6. Handle Linux and macOS Docker socket GID differences.
7. `capsule.sh` resolves UID/GID via `id -u` / `id -g`.
   `CAPSULE_UID` / `CAPSULE_GID` override. Fallback: `1000:100`.
8. `docker/entrypoint.sh` adjusts UID/GID, Docker socket group,
   and home ownership, then drops privileges.
9. Keep baseline image tools: `rg`, `fd`, `jq`, `shellcheck`,
   `gh`, `tree`.
10. When Dockerfile tool packages change, update README docs and tests.

## Structure

- `Dockerfile`: Debian-based image with dev tools, `mise`,
  Docker CLI/Compose, Copilot/Codex CLIs, Python, `ruff`, and `ty`.
- `compose.yml`: Local `cli` service; mounts workspace, Docker socket,
  and home volume; provides build and runtime `github_api_token` secret.
- `capsule.sh`: Launcher; handles allowlist, UID/GID, build flags,
  and Compose invocations.
- `docker/entrypoint.sh`: Root entrypoint; syncs UID/GID, Docker group,
  and home ownership, then execs as `user`.
- `docker/setup-docker.sh`: Installs Docker APT repo, CLI, Compose,
  and buildx.
- `docker/mise.sh`: Activates `mise` and Bash completions for
  interactive shells.
- `tests/check_all.sh`: Repo-wide lint/check script.
- `tests/suite_fast.sh`: Fast Bash contract tests.
- `tests/suite_e2e.sh`: Docker-backed end-to-end test.
- `tests/test_all.sh`: Runs fast then e2e suites.
