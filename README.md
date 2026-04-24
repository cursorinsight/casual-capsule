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

## Table of contents

- [Prerequisites](#-prerequisites)
- [Initial setup](#-initial-setup)
  - [Phase 1: Prepare credentials](#phase-1-prepare-credentials)
  - [Phase 2: Start Capsule](#phase-2-start-capsule)
  - [Phase 3: Verify the container](#phase-3-verify-the-container)
  - [Phase 4: Verify GitHub auth](#phase-4-verify-github-auth)
  - [Phase 5: Verify Copilot (optional)](#phase-5-verify-copilot-optional)
  - [Phase 6: Verify Codex (optional)](#phase-6-verify-codex-optional)
- [Usage](#-usage)
- [Capsule command examples](#%EF%B8%8F-capsule-command-examples)
- [Additional features](#-additional-features)
  - [UID and GID detection](#uid-and-gid-detection)
  - [Directory approval list](#directory-approval-list)
  - [Custom Capsule images](#custom-capsule-images)
  - [Bind mounts in containers started in a Capsule](#bind-mounts-in-containers-started-in-a-capsule)
- [Configuration reference](#-configuration-reference)
  - [Command line options](#command-line-options)
  - [Environment variables](#environment-variables)
- [Run tests](#-run-tests)
- [Included agent tooling](#-included-agent-tooling)
- [Security Note](#-security-note)
- [License](#-license)

## 📋 Prerequisites

- Docker Engine 24+ and Docker Compose v2
- Access to GitHub Copilot or Codex.

## 🚀 Initial setup

There is no true quick start for the first run. Capsule persists GitHub auth
state in the home volume, so it is worth doing setup in this order: prepare the
token first, then start Capsule, then verify the workspace and `gh` auth before
opening Copilot or Codex. These checkpoints make later troubleshooting much
easier.

| Phase | What it proves |
| --- | --- |
| Prepare credentials | The first Capsule run can persist working GitHub auth. |
| Start Capsule | The image builds and the container starts successfully. |
| Verify the container | The workspace mount and persistent home volume work. |
| Verify GitHub auth | `gh` is already logged in before agent startup. |
| Verify your agent | Copilot or Codex can read the workspace. |

### Phase 1: Prepare credentials

1.  Decide if you want to use GitHub Copilot, Codex, or both.

2.  Generate a GitHub access token.

    1.  Open <https://github.com/settings/personal-access-tokens>.

    2.  Make sure that you are logged in.

    3.  Click on the "Generate new token" button.

    4.  Confirm access if the UI asks you to do so.

    5.  Fill in the "New fine-grained personal access token" form:

        *   Token name: Choose any name. For example, "Capsule".

        *   Fill in the other fields as you see fit. It's ok to leave them on
            the default values.

    6.  If you want to use Copilot, add the necessary permissions.

        1.  Click on the "Add permission" button.

        2.  Choose the following permissions:

            *   Copilot Chat

            *   Copilot Editor Context

            *   Copilot Requests

            *   Models

            *   Plan

    7.  Click on the "Generate token" button below the form.

    8.  Click on the "Generate token" button in the popup window.

    9.  Copy the token and save it somewhere safe.

    10. You may close the GitHub website.

3.  Create a project directory that we can use as a test.

    ```
    $ mkdir /home/myuser/myproject
    $ cd /home/myuser/myproject
    $ echo "My favorite color is purple." > AGENTS.md
    ```

4.  Create an alias:

    ```
    alias capsule="/absolute/path/to/casual-capsule/capsule.sh"
    ```

    You might want to add this to your init script (such as `~/.bashrc` or
    `~/.zshrc`).

5.  Set `GITHUB_API_TOKEN` to the value you received from GitHub (replace
    `[GITHUB_API_TOKEN]`).

    Set this before the first build/run so the persistent home volume starts
    with working GitHub auth.

    ```
    $ export GITHUB_API_TOKEN=[GITHUB_API_TOKEN]
    ```

### Phase 2: Start Capsule

1.  Build the Capsule Docker image and start it in the current directory.

    ```
    $ capsule --build
    ```

2.  When Capsule asks the following, type "y".

    ```
    Allow capsule to run in /home/myuser/myproject (y/N)?
    ```

3.  You should see that Docker builds the Capsule image, creates a container and
    starts it:

    ```
    $ capsule --build
    Allow capsule to run in /home/myuser/myproject (y/N)? y
    [...]
    [+] build 1/1
     ✔ Image hcs-capsule:local Built
     ✔ Volume casual-capsule_home Created
    Container casual-capsule-cli-run-4d7e2776d2fd Creating
    Container casual-capsule-cli-run-4d7e2776d2fd Created
    user@capsule:/home/workspace$
    ```

    **Checkpoint:** the base image built and Capsule started successfully.

### Phase 3: Verify the container

1.  Check your workspace:

    ```
    user@capsule:/home/workspace$ cat AGENTS.md
    My favorite color is purple.
    ```

    Your `/home/myuser/myproject` directory is mounted to `/home/workspace`
    inside the container.

    **Checkpoint:** the workspace bind mount is correct before you start an
    agent.

2.  Check the user home directory:

    ```
    user@capsule:/home/workspace$ cat /home/user/.config/gh/hosts.yml
    github.com:
        users:
            myuser:
                oauth_token: [GITHUB_API_TOKEN]
        oauth_token: [GITHUB_API_TOKEN]
        user: myuser
    ```

    The Docker daemon created a `casual-capsule_home` Docker volume when it
    started the container. This volume is mounted to `/home/user`. This volume
    is persistent and shared between Capsule instances.

    The `/home/user/.config/gh/hosts.yml` file should contain your GitHub API
    token.

    **Checkpoint:** the persistent home volume contains the expected GitHub
    auth configuration.

### Phase 4: Verify GitHub auth

1.  Check that you are logged in to GitHub.

    ```
    user@capsule:/home/workspace$ gh auth status
    github.com
      ✓ Logged in to github.com account myuser (/home/user/.config/gh/hosts.yml)
      - Active account: true
      - Git operations protocol: https
      - Token: [GITHUB_API_TOKEN]
    ```

    **Checkpoint:** `gh` is ready before you open Copilot or Codex.

    If `gh auth status` says that you are not logged in, add your GitHub token
    to `github_api_token.txt` (inside the container) and log in manually:

    ```
    $ gh auth login --with-token < github_api_token.txt
    ```

    You can do the same when your token expires in the future.

### Phase 5: Verify Copilot (optional)

1.  Start Copilot:

    ```
    $ copilot
    ```

2.  Copilot asks if you trust `/home/workspace`.

    Choose the following response: "Yes, and remember this folder for future
    sessions."

3.  Test the connection and that Copilot can read `AGENTS.md`:

    ```
    ❯ What is my favorite color?
    ● Your favorite color is purple! 💜
    ```

### Phase 6: Verify Codex (optional)

1.  Start Codex:

    ```
    $ codex
    ```

2.  Select "Sign in with Device Code."

3.  Follow the instructions to log in.

4.  Codex asks if you trust `/home/workspace`.

    Choose the following response: "Yes, continue".

5.  Codex probably prints the following warning:

    ```
    Codex could not find bubblewrap on PATH. Install bubblewrap with your OS
    package manager. See the sandbox prerequisites:
    https://developers.openai.com/codex/concepts/sandboxing#prerequisites.
    Codex will use the vendored bubblewrap in the meantime.
    ```

    You can continue this setup, but later you might want to fix this warning.
    There are at least two ways:

    *   One way to eliminate this warning is to run `codex` with
        `--dangerously-bypass-approvals-and-sandbox`. This disables the sandbox
        which would use `bubblewrap`.

    *   Another way to eliminate the warning is to use a custom `compose.yml`
        file that adds `privileged: True` to the `cli` service, and use a
        custom `Dockerfile` that installs the `bubblewrap` package with `apt`.
        See more information about this kind of customization in the *Custom
        Capsule images* section.

6.  Test the connection and that Codex can read `AGENTS.md`:

    ```
    › What is my favorite color?
    • Your favorite color is purple.
    ```

## 💡 Usage

Once you set up Capsule, you can start it in any project directory. You can even
start Copilot or Codex directly:

```
$ cd /home/myuser/myproject
$ capsule copilot
$ capsule codex
```

## ⌨️ Capsule command examples

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

## 🧩 Additional features

### UID and GID detection

Capsule auto-detects the host user's UID/GID via `id -u`/`id -g` and
`DOCKER_GID` from the active Docker socket (falling back to `991` on macOS,
`999` on Linux). If UID/GID detection fails (e.g. `id` is unavailable), it falls
back to `1000:100` and prints a warning. The entrypoint handles UID/GID
adjustment and Docker socket group membership at startup.

This mechanism ensures that the user inside the container can access the
`/home/workspace` directory and the host's Docker daemon.

You can override UID/GID or DOCKER_GID by using environment variables:

```bash
CAPSULE_UID=2000 CAPSULE_GID=2000 capsule
```

Bake a custom UID/GID into the image (avoids runtime `chown`):

```bash
CAPSULE_UID=2000 CAPSULE_GID=2000 capsule --build
```

### Directory approval list


On the first run in a new directory, `capsule.sh` prompts for explicit approval
and records the approved path in `~/.config/capsule` (overridable via
`CAPSULE_CONFIG`).

### Custom Capsule images

If you want to extend the Docker image or Compose configuration provided by
Capsule, you can do that by creating a custom `compose.yml` file and setting its
path in `CAPSULE_CUSTOM_COMPOSE`.

The custom `compose.yml` file must override the `cli` section.

Example layout:

```text
/home/myuser/python-capsule/
|- Dockerfile
`- compose.yml
```

Example `Dockerfile`:

```dockerfile
FROM casual-capsule:local

RUN uv tool install black
```

Example `compose.yml`:

```yaml
services:
  cli:
    image: python-capsule:local
    build:
      context: ${CAPSULE_CUSTOM_DIR}
      dockerfile: ${CAPSULE_CUSTOM_DIR}/Dockerfile
    environment:
      PYTHON_CAPSULE: "1"
```

Use it like this:

```bash
export CAPSULE_CUSTOM_COMPOSE=/home/myuser/python-capsule/compose.yml
./capsule --build
```

With a custom compose file, `capsule.sh --build` first rebuilds the base image
`casual-capsule:local`, then builds the merged custom `cli` image, and finally
starts the container from that merged configuration.

### Bind mounts in containers started in a Capsule

When you start a Docker container inside a Capsule Docker container, sometimes
you want to mount directories to that container that are in the workspace
(`/home/workspace`). For example `tests/suite_e2e.sh` does this.

So when you do this, `capsule.sh` translates directory paths as seen on the
container (for example, `/home/workspace/mydir`) back to the original host path
(for example, `/home/myuser/myproject/mydir`) before asking the Docker server
(which runs on the host machine) to create the workspace bind mount.

For this mechanism to work, you need to set the environment variable
`CAPSULE_HOST_WORKDIR` when starting the container.

```bash
CAPSULE_HOST_WORKDIR=$(pwd) capsule
```

See more information about it in `capsule.sh`.

## 🔧 Configuration reference

### Command line options

Usage:

```
capsule.sh [OPTIONS]
capsule.sh [OPTIONS] -- [ARGS]
```

Options:

*   `-b`, `--build`: Run `docker compose build cli` before `run`.

*   `-h`, `--help`: Show usage message.

*   `--`: Stop launcher option parsing; pass remaining arguments to
    `docker compose run cli`.

### Environment variables

*   `CAPSULE_DEBUG`: Enable shell xtrace for `capsule.sh`.

    Default: empty. When set to `1`, `capsule.sh` runs with `set -x`.

*   `CAPSULE_UID`: Container user UID (user ID).

    Default: The output of `id -u` on the host. If that doesn't work, then 1000.

*   `CAPSULE_GID`: Container user GID (group ID).

    Default: The output of `id -g` on the host. If that doesn't work, then 100.

*   `DOCKER_GID`: Docker socket GID.

    Default: Auto-detected from the host.

*   `CAPSULE_WORKDIR`: Workspace directory.

    Default: current working directory.

*   `CAPSULE_CUSTOM_COMPOSE`: Optional custom compose override file.

    Default: empty.

*   `CAPSULE_CONFIG`: Path to the file that contains the approved directories.

    Default: `~/.config/capsule`.

*   `CAPSULE_HOST_WORKDIR`: host-visible path for `/home/workspace`.

    Default: empty.

*   `GITHUB_API_TOKEN`: Passed as a build secret for `gh` auth and Copilot CLI.

## 🧪 Run tests

Run the tests on the host:

```bash
$ tests/test_all.sh
```

Run the tests inside a Capsule:

```
$ CAPSULE_HOST_WORKDIR=$(pwd) capsule tests/test_all.sh
```

`test_all.sh` prints each suite name before running it.

*   The fast suite uses command stubs, so it does not require a running Docker
    daemon.

*   The end-to-end suite builds and runs the real capsule image when Docker and
    Compose are available. It skips cleanly when the daemon is unavailable.

    The end-to-end suite also prints the path to a per-run logfile under
    `_build/tests/`. The logfile is kept after the run and records suite events
    and plain Docker/Capsule output with UTC timestamps on every line.

## 🤖 Included agent tooling

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
