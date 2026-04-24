# AGENTS.md

## Core Workflow

1. Keep changes small, focused, and easy to review.
2. Update docs when behavior or workflow changes.
3. Do not rewrite shared history unless explicitly requested.
4. Validate changes locally when practical.
5. When adding shell flags or argument parsing, include edge-case tests for
   empty-argument invocations.

## Git usage

### Commit Ownership

1. The repository owner creates and GPG-signs commits.
2. Agents must not run `git commit` unless explicitly asked.
3. If asked for a message, base it on currently staged changes.
4. If staged and unstaged differ, state that the message is staged-only.

### Commit Message Rules

1. Headline format: `<type>(<scope>): <Headline>`.
2. Use a prefix and capitalize the first character of the headline.
3. Keep headline length at 72 characters maximum.
4. Write the body as bullet points.
5. Write each bullet as a full sentence explaining what changed and why.

### Commit Attribution

Include an `Assisted-by` trailer for every commit where an AI agent
contributed, following the Linux kernel gen-AI attribution convention:

```
Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

- `AGENT_NAME` is the name of the AI tool or framework.
- `MODEL_VERSION` is the specific model version used.
- `[TOOL1] [TOOL2]` are optional specialised analysis tools (e.g.
  `shellcheck`, `sparse`); basic tools (`git`, editors) are omitted.

Example trailer block:

```
Assisted-by: Copilot:claude-sonnet-4.6
```

## Style Rules

1. Keep code and config lines at 80 characters maximum.
2. Keep shell scripts compatible with Bash 3.2+ unless the file explicitly
   requires a newer Bash version.

## Docker and Compose

1. Prefer reproducible images by pinning key runtime/tool versions.
2. Minimize packages and run as non-root unless root is required.
3. Keep configuration portable; avoid user-specific absolute host paths.
4. Keep secrets in runtime environment or secret managers, never hardcoded.
5. For interactive shells, do not use auto-restart policies.
6. For Docker socket access, support Linux and macOS group-ID differences.
7. `capsule.sh` auto-detects the host user's UID/GID via `id -u`/
   `id -g`; explicit `CAPSULE_UID`/`CAPSULE_GID` env vars take
   precedence; the fallback when detection fails is `1000:100`.
   The entrypoint adjusts UID/GID, handles `DOCKER_GID` group
   membership, and fixes stale volume ownership at runtime.
8. Keep baseline agent utilities installed in the image: `rg`, `fd`,
   `jq`, `shellcheck`, `gh`, and `tree`.
9. When changing Dockerfile tool packages, update README tooling docs
   and tests to keep the tooling contract explicit.

## Project Structure

- `Dockerfile`: Main image based on `debian:trixie-slim`; installs development
  and build tools, then uses `mise` to manage agent utilities (`bat`, `eza`,
  `fd`, `gh`, `jq`, `rg`, `uv`), Docker CLI, Compose plugin, Copilot and Codex
  CLI; installs Python, `ruff`, and `ty` via `uv`.
- `docker/entrypoint.sh`: Startup script that runs as root, adjusts the
  container user to match `CAPSULE_UID`/`CAPSULE_GID`, adds it to the Docker
  socket group, and drops privileges via `setpriv`.
- `docker/setup-docker.sh`: Configures the Docker APT source and installs
  `docker-ce-cli`, `docker-compose-plugin`, and
  `docker-buildx-plugin`.
- `docker/mise.sh`: Placed in `/etc/profile.d/`; activates mise and its shell
  completions for interactive shells.
- `compose.yml`: Local Compose service (`cli`) that builds from `Dockerfile`,
  publishes the stable base image name `casual-capsule:local`, and adds Docker
  socket access via `DOCKER_GID`. The container user matches the host user's
  UID/GID (auto-detected by `capsule.sh`); override with `CAPSULE_UID`/
  `CAPSULE_GID`. Also sets hostname `capsule` and persists the home directory
  in a named volume.
- `capsule.sh`: Launcher script for running the CLI from any project directory.
- `tests/suite_fast.sh`: Fast Bash tests for the launcher and Compose contract.
- `tests/suite_e2e.sh`: Docker-backed end-to-end example-project test.
- `tests/test_all.sh`: Runs the fast and end-to-end suites in order.
