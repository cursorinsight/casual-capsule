# Casual Capsule

Containerized CLI workspace for AI coding agents (`codex`, Copilot CLI) with
common developer tools.

## What is in this repo

- `Dockerfile`: Main image based on `jdxcode/mise` with Node, Go, npm,
  Codex, OpenAI CLI, Docker CLI, Compose plugin, and Copilot CLI.
- `compose.yml`: Local compose service (`cli`) that builds from `Dockerfile`,
  runs as `8888:100`, and adds Docker socket access via `DOCKER_GID`.
- `capsule.sh`: Launcher script for running the CLI from any project
  directory.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2

## Usage

### 1. Build the main image

```bash
docker build -t casual-capsule:latest .
```

### 2. Run the main image (interactive shell)

```bash
docker run --rm -it \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  -e DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)" \
  -w /workspace \
  --user 8888:100 \
  --group-add "${DOCKER_GID}" \
  -v "$PWD:/workspace" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  casual-capsule:latest
```

Inside container:

```bash
codex
copilot
```

### 3. Use `capsule.sh` (recommended)

`capsule.sh` sets `CAPSULE_WORKDIR` to your current directory and runs the
CLI service from this repository's Compose file. `compose.yml` falls back to
`CC_WORKDIR` and then `PWD` if `CAPSULE_WORKDIR` is not set. It also detects
`DOCKER_GID` from the active Docker socket when possible.
The service runs as `uid=8888,gid=100` and uses `group_add` with
`DOCKER_GID` for host Docker socket access.
If detection fails, it defaults to `991` on macOS and `999` on Linux.
On macOS, if auto-detection returns `20` (`staff`), `capsule.sh` overrides it
to `991` because `20` is commonly not usable for Docker socket access here.
If you export `DOCKER_GID` yourself, `capsule.sh` keeps your explicit value.

From this repo:

```bash
./capsule.sh
```

From any directory, with an alias:

```bash
alias capsule="/absolute/path/to/casual-capsule/capsule.sh"
```

Add that alias to one of these files:

- Bash: `~/.bashrc` (or `~/.bash_profile`)
- Zsh: `~/.zshrc`

Then reload your shell and run:

```bash
capsule
```

Optional: pass a command instead of the default shell.

```bash
capsule codex
capsule bash -lc "go version && node -v"
capsule docker ps
```

### 4. Use Docker Compose directly

If you prefer direct Compose commands:

```bash
docker compose up --build
```

If Docker socket permissions fail, set `DOCKER_GID` and retry:

```bash
export DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
docker compose run --rm cli docker ps
```

On macOS, use:

```bash
export DOCKER_GID="$(stat -f '%g' /var/run/docker.sock)"
docker compose run --rm cli docker ps
```

Note: the injected Docker group may appear as a numeric GID inside the
container if no matching group name exists in `/etc/group`.

## Security Note

This setup mounts `/var/run/docker.sock` into the container so processes inside
the container can control the host Docker daemon.
Treat this as effectively host-level access. Do not use this setup with
untrusted code, untrusted users, or shared multi-tenant hosts.

## Code Review Findings

### High

1. Resolved: host-specific volume mounts were replaced with portable working
   directory environment variables for better portability.
   - `compose.yml:10`
   - `compose.yml:11`
   - `compose.yml:12`
   - `compose.yml:13`
2. Resolved: Node setup now uses a stable major (`24`) without a
   conflicting `latest` selector.
   - `Dockerfile:25`
   - `Dockerfile:26`

### Medium

1. Resolved: restart policy is now `no` for an interactive CLI service.
   - `compose.yml:8`
2. Resolved: image provisioning no longer runs `apt-get upgrade`,
   reducing package drift risk.
   - `Dockerfile:6`

### Low

1. README previously lacked runnable setup details and operational
   notes; this file now provides baseline usage.
   - `README.md:1`

## Suggested Follow-up Fixes

1. Pin base image digests for stronger reproducibility.
2. Add shell completion for `capsule.sh` command argument passthrough.
