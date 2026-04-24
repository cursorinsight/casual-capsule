# 💊 Casual Capsule

[![ci](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Base image](https://img.shields.io/badge/base-debian%3Atrixie--slim-informational?logo=debian)](Dockerfile)
[![Shell](https://img.shields.io/badge/shell-bash-green?logo=gnu-bash)](capsule.sh)
[![Shellcheck](https://img.shields.io/badge/lint-shellcheck-yellow)](https://www.shellcheck.net)
[![Tooling](https://img.shields.io/badge/tools-mise-orange)](https://mise.jdx.dev)
[![Tooling](https://img.shields.io/badge/tools-uv-orange)](https://docs.astral.sh/uv/)

Containerized CLI workspace for AI coding agents (Copilot CLI, Codex CLI) with
common developer tools.

## 📁 Project Structure

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
  container.
- `compose.yml`: Local Compose service (`cli`) that builds from `Dockerfile` and
  adds Docker socket access via `DOCKER_GID`. The container user matches the
  host user's UID/GID (auto-detected by `capsule.sh`); override with
  `CAPSULE_UID`/`CAPSULE_GID`. Also sets hostname `capsule` and persists the
  home directory in a named volume.
- `capsule.sh`: Launcher script for running the CLI from any project directory.
- `tests/suite_fast.sh`: Fast Bash tests for the launcher and Compose contract.
- `tests/suite_e2e.sh`: Docker-backed end-to-end example-project test.
- `tests/test_all.sh`: Runs the fast and end-to-end suites in order.

## 📋 Prerequisites

- Docker Engine 24+ and Docker Compose v2

## 🚀 Usage

### 1. Build the main image

```bash
docker build -t casual-capsule:latest .
```

To pass a GitHub API token as a build secret (enables `gh` auth and Copilot CLI
activation at build time):

```bash
GITHUB_API_TOKEN=ghp_… docker build \
  --secret id=github_api_token,env=GITHUB_API_TOKEN \
  -t casual-capsule:latest .
```

### 2. Run the main image (interactive shell)

```bash
docker run --rm -it \
  -e DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)" \
  -w /home/workspace \
  -v "$PWD:/home/workspace" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  casual-capsule:latest
```

The entrypoint runs as root, adjusts the container user to
`CAPSULE_UID`:`CAPSULE_GID` (default `1000:100`), adds it to the `DOCKER_GID`
group, sets `HOME`/`USER`/`LOGNAME`, and drops privileges. No `--user` or
`--group-add` flags required.

Inside container:

```bash
copilot
```

### 3. Use `capsule.sh` ✨ (recommended)

`capsule.sh` sets `CAPSULE_WORKDIR` to your current directory and runs the CLI
service via Compose. It auto-detects the host user's UID/GID via `id -u`/`id -g`
and `DOCKER_GID` from the active Docker socket (falling back to `991` on macOS,
`999` on Linux). If UID/GID detection fails (e.g. `id` is unavailable), it falls
back to `1000:100` and prints a warning. The entrypoint handles UID/GID
adjustment and Docker socket group membership at startup.

On the first run in a new directory, `capsule.sh` prompts for explicit approval
and records the approved path in `~/.config/capsule` (overridable via
`CAPSULE_CONFIG`).

Override UID/GID or DOCKER_GID via environment:

```bash
CAPSULE_UID=2000 CAPSULE_GID=2000 capsule
```

Bake a custom UID/GID into the image (avoids runtime `chown`):

```bash
CAPSULE_UID=2000 CAPSULE_GID=2000 capsule --build
```

#### ⚙️ Launcher options

- `-b`, `--build`: Run `docker compose build cli` before `run`.
- `-h`, `--help`: Show usage message.
- `--`: Stop launcher option parsing; pass remaining args to runtime.

#### ⚙️ Environment variables

- `CAPSULE_UID`: Container user UID (auto-detected from host).
- `CAPSULE_GID`: Container user GID (auto-detected from host).
- `DOCKER_GID`: Docker socket GID (auto-detected).
- `CAPSULE_WORKDIR`: Workspace directory (default: cwd).
- `CAPSULE_CONFIG`: Path to the allowlist file (default: `~/.config/capsule`).
- `GITHUB_API_TOKEN`: Passed as a build secret for `gh` auth and Copilot CLI.

#### 🔧 Install as an alias

From this repo:

```bash
./capsule.sh
```

From any directory, add an alias to your shell profile:

```bash
# Bash: ~/.bashrc or ~/.bash_profile
# Zsh:  ~/.zshrc
alias capsule="/absolute/path/to/casual-capsule/capsule.sh"
```

Then reload your shell and run:

```bash
capsule
```

#### Bind mounts in containers started in a Capsule

When you start a Docker container inside a Capsule Docker container, sometimes
you want to mount directories to that container that are in the workspace
(`/home/workspace`). For example `tests/suite_e2e.sh` does this.

So when you do this, `capsule.sh` translates directory paths as seen on the
container (for example, `/home/workspace/mydir`) back to the original host path
(for example, `/home/myuser/myproject/mydir`) before asking the Docker server
(which runs on the host machine) to create the workspace bind mount.

For this mechanism to work, you need to set the following environment variable
when starting the container:

- `CAPSULE_HOST_WORKDIR`: host-visible path for `/home/workspace`.

See more information about it in `capsule.sh`.

#### Examples

Pass a command instead of the default shell:

```bash
capsule copilot
capsule bash -lc "node -v && python --version"
capsule docker ps
```

Build the image before starting:

```bash
capsule --build
capsule -b copilot
```

Use `--` when arguments overlap launcher flags:

```bash
capsule -- --build true
```

### 4. Use Docker Compose directly

```bash
docker compose run --rm cli
```

Build and run in one step:

```bash
docker compose run --rm --build cli
```

If Docker socket permissions fail, set `DOCKER_GID` and retry:

```bash
# Linux
export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
# macOS
export DOCKER_GID="$(stat -f '%g' /var/run/docker.sock)"

docker compose run --rm cli
```

### 5. 🧪 Run tests

```bash
CAPSULE_HOST_WORKDIR=$(pwd) tests/test_all.sh
```

`test_all.sh` prints each suite name before running it.

*   The fast suite uses command stubs, so it does not require a running Docker
    daemon.

*   The end-to-end suite builds and runs the real capsule image when Docker and
    Compose are available. It skips cleanly when the daemon is unavailable.

    The end-to-end suite also prints the path to a per-run logfile under
    `_build/tests/`. The logfile is kept after the run and records suite events
    and plain Docker/Capsule output with UTC timestamps on every line.

### 6. 🤖 Included agent tooling

The image includes utilities commonly used by coding agents, installed via
`mise` (configured in the `MISE_SYSTEM_TOOLS` Dockerfile ARG):

- `bat`: Syntax-highlighted file viewing.
- `eza`: Enhanced directory listing.
- `fd`: Fast file discovery.
- `gh`: GitHub CLI operations.
- `jq`: JSON filtering and inspection.
- `rg` (`ripgrep`): Fast content search.
- `uv`: Python version, tool, and environment management.

Installed via `apt`:

- `shellcheck`: Shell script linting.
- `tree`: Directory structure visualization.

Python tooling (installed via `uv`; binaries available on `PATH` via
`~/.local/bin`):

- `python`: Python runtime (version set by `PYTHON_VERSION` ARG, default
  `3.14`).
- `ruff`: Fast Python linter and formatter.
- `ty`: Python type checker.

Verify inside capsule:

```bash
capsule bash -lc "rg --version && fd --version && jq --version && \
  bat --version && eza --version && shellcheck --version && \
  gh --version && tree --version && python --version"
```

## 🔐 Security Note

This setup mounts `/var/run/docker.sock` into the container, giving it
host-level Docker access. Do not use with untrusted code or shared hosts.

## 📄 License

Copyright 2026 Cursor Insight

Licensed under the [Apache License, Version 2.0](LICENSE).
