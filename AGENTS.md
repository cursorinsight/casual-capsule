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
  Docker CLI/Compose, `podman`, Claude/Codex CLIs, Python, `ruff`, and
  `ty`. `CAPSULE_WITH_DOCKERD=1` adds a real Docker Engine.
- `compose.yml`: Local privileged `cli` service; mounts workspace, Docker
  socket, and home volume; permits nested Podman tests; provides the build
  and runtime `github_api_token` secret.
- `capsule.sh`: Launcher; selects the podman or Docker backend, and
  handles allowlist, UID/GID, build flags, and runtime invocations.
- `capsule-doctor.sh`: Host environment check; reports what each backend
  needs and the command that repairs what is missing.
- `docker/entrypoint.sh`: Root entrypoint; syncs UID/GID, Docker socket
  group, nested Podman ID ranges, and home ownership, then execs as `user`.
  Under podman the container already starts as `user`, so it only refreshes
  credentials.
- `docker/capsule-docker.sh`: The Capsule's `docker` router and the
  `capsule-docker` engine switch; starts the podman API socket or a
  rootless `dockerd` on first use.
- `docker/codex.sh`: Starts Codex with approvals and sandboxing disabled.
- `docker/containers.conf`, `docker/registries.conf`,
  `docker/storage.conf`: Configuration for the Capsule's inner engine,
  including the per-workspace storage path.
- `docker/setup-docker.sh`: Installs Docker APT repo, CLI, Compose,
  buildx, and the Engine when `CAPSULE_WITH_DOCKERD=1`.
- `docker/mise.sh`: Activates `mise` and Bash completions for
  interactive shells.
- `tests/check_all.sh`: Repo-wide lint/check script.
- `tests/suite_fast.sh`: Fast Bash contract tests.
- `tests/suite_e2e.sh`: Docker- and podman-backed end-to-end tests;
  the podman case skips where the host cannot run rootless.
- `tests/test_all.sh`: Runs fast then e2e suites.
