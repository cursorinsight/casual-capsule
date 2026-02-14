# Casual Capsule

Containerized CLI workspace for AI coding agents (`codex`, Copilot CLI) with
common developer tools.

## What is in this repo

- `Dockerfile`: Main image based on `jdxcode/mise` with Node, Go, npm,
  Codex, OpenAI CLI, Copilot, and Vim plugin setup.
- `compose.yml`: Local compose service (`cli`) that builds from `Dockerfile`.

## Prerequisites

- Docker Engine 24+ and Docker Compose v2
- OpenAI API key (`OPENAI_API_KEY`)
- Optional GitHub token (`GITHUB_TOKEN`) for GitHub/Copilot integrations

## Usage

### 1. Build the main image

```bash
docker build -t casual-capsule:latest .
```

### 2. Run the main image (interactive shell)

```bash
docker run --rm -it \
  -e OPENAI_API_KEY \
  -e GITHUB_TOKEN \
  -w /workspace \
  -v "$PWD:/workspace" \
  -v "$HOME/.codex:/home/user/.codex" \
  -v "$HOME/.config/gh:/home/user/.config/gh" \
  -v "$HOME/.local/share/gh:/home/user/.local/share/gh" \
  casual-capsule:latest
```

Inside container:

```bash
codex
copilot
```

### 3. Use Docker Compose

`compose.yml` now uses:

- `${PWD}` for the project working directory (mounted at `/workspace`)
- `${HOME}` for user config mounts

Then run:

```bash
docker compose up --build
```

## Code Review Findings

### High

1. Resolved: host-specific volume mounts were replaced with `${PWD}`
   and `${HOME}` for portability.
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
2. Add a thin launcher script for Compose so `${PWD}` is always
   exported predictably across shells and OS setups.
