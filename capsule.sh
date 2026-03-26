#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

# This block sets two variables:
#
# *   CAPSULE_WORKDIR is the path of the working directory (project directory)
#     as seen by the process running this script. This script's job is to start
#     a container and to map CAPSULE_WORKDIR to /home/workspace inside that
#     container. This happens in compose.yml.
#
# *   CAPSULE_HOST_WORKDIR is a bit more complicated:
#
#     -   When this script starts:
#
#         *   If capsule.sh is running on the host machine,
#             CAPSULE_HOST_WORKDIR is not set.
#
#         *   If capsule.sh is running inside a capsule (that is, a container
#             started by another execution of capsule.sh),
#             CAPSULE_HOST_WORKDIR is the directory on the host that is mapped
#             to /home/workspace inside the container.
#
#     -   After the if construct below:
#
#         *   CAPSULE_HOST_WORKDIR will point to the same directory as
#             CAPSULE_WORKDIR, but on the host machine (where the Docker daemon
#             is running).
#
# To sum up: the following values all point to the same working directory, but
# in different systems:
#
# *   CAPSULE_HOST_WORKDIR (after the if construct below): The working
#     directory's path on the host machine.
#
# *   CAPSULE_WORKDIR: The working directory's path on the machine where this
#     capsule.sh is running. This might be on the host machine or in a
#     capsule container. If it's in a container, it will be either
#     /home/workspace or /home/workspace/[...].
#
# *   /home/workspace: The working directory's path in the container started by
#     capsule.sh.
export CAPSULE_WORKDIR="${CAPSULE_WORKDIR:-$(pwd -P)}"
CAPSULE_CONTAINER_WORKDIR="/home/workspace"
_CAPSULE_ID_WARN=0

if [[ -z "${CAPSULE_HOST_WORKDIR:-}" ]]; then
  export CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
elif [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR" ]]; then
  export CAPSULE_HOST_WORKDIR
elif [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR"/* ]]; then
  CAPSULE_HOST_WORKDIR="$(
    printf '%s%s' \
      "$CAPSULE_HOST_WORKDIR" \
      "${CAPSULE_WORKDIR#"$CAPSULE_CONTAINER_WORKDIR"}"
  )"
  export CAPSULE_HOST_WORKDIR
else
  # A non-Capsule path inside a container is not host-mountable via DOOD.
  # Fall back to the local path and let Docker surface any mount error.
  export CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
fi

# Resolve container UID: env > host id > default 1000.
if [[ -n "${CAPSULE_UID:-}" ]]; then
  export CAPSULE_UID
elif CAPSULE_UID="$(id -u 2>/dev/null)" \
     && [[ -n "$CAPSULE_UID" ]]; then
  export CAPSULE_UID
else
  export CAPSULE_UID=1000
  _CAPSULE_ID_WARN=1
fi

# Resolve container GID: env > host id > default 100.
if [[ -n "${CAPSULE_GID:-}" ]]; then
  export CAPSULE_GID
elif CAPSULE_GID="$(id -g 2>/dev/null)" \
     && [[ -n "$CAPSULE_GID" ]]; then
  export CAPSULE_GID
else
  export CAPSULE_GID=100
  _CAPSULE_ID_WARN=1
fi

if [[ "$_CAPSULE_ID_WARN" -eq 1 ]]; then
  printf 'capsule: warning: %s (%s:%s)\n' \
    "cannot detect host UID/GID; using defaults" \
    "$CAPSULE_UID" "$CAPSULE_GID" >&2
fi
BUILD_BEFORE_RUN=0
RUNTIME_ARGS=()

usage() {
  cat <<'EOF'
Usage: capsule.sh [options] [--] [command...]

Options:
  -b, --build  Run "docker compose build cli" before runtime.
  -h, --help   Show this help message.

Environment:
  CAPSULE_UID      Container user UID (auto-detected).
  CAPSULE_GID      Container user GID (auto-detected).
  DOCKER_GID       Docker socket GID (auto-detected).
  CAPSULE_WORKDIR  Workspace directory (default: cwd).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build)
      BUILD_BEFORE_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      RUNTIME_ARGS+=("$@")
      break
      ;;
    *)
      RUNTIME_ARGS+=("$1")
      shift
      ;;
  esac
done

# Require explicit approval before mounting a host path into the container.
CAPSULE_CONFIG=${CAPSULE_CONFIG:-"${HOME}/.config/capsule"}
mkdir -p "$(dirname "${CAPSULE_CONFIG}")"
if ! grep -Fxqs "${CAPSULE_WORKDIR}" "${CAPSULE_CONFIG}"; then
    if [[ ! -t 0 ]]; then
        printf 'capsule: error: %s not in allowlist; ' \
            "${CAPSULE_WORKDIR}" >&2
        printf 'pre-approve in %s\n' "${CAPSULE_CONFIG}" >&2
        exit 1
    fi
    read -rs -n 1 -p "Allow capsule to run in ${CAPSULE_WORKDIR} (y/N)? " key
    if [[ $key == 'y' || $key == 'Y' ]]; then
        printf 'y\n' >&2
        printf '%s\n' "${CAPSULE_WORKDIR}" >>"${CAPSULE_CONFIG}"
    else
        printf 'n\n' >&2
        exit 1
    fi
fi

if [[ -z "${DOCKER_GID:-}" ]]; then
  DOCKER_SOCK_PATH=""
  DOCKER_HOST_SOCK_PATH=""

  # Prefer the active Docker socket so the container user can access the
  # daemon through the mounted socket without running as root.
  if [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" == unix://* ]]; then
    DOCKER_HOST_SOCK_PATH="${DOCKER_HOST#unix://}"
    if [[ -e "${DOCKER_HOST_SOCK_PATH}" ]]; then
      DOCKER_SOCK_PATH="${DOCKER_HOST_SOCK_PATH}"
    fi
  fi

  if [[ -z "${DOCKER_SOCK_PATH}" ]] && [[ -e /var/run/docker.sock ]]; then
    DOCKER_SOCK_PATH="/var/run/docker.sock"
  elif [[ -z "${DOCKER_SOCK_PATH}" ]] && command -v docker >/dev/null 2>&1; then
    CONTEXT_HOST="$(docker context inspect \
      --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
    if [[ "${CONTEXT_HOST}" == unix://* ]]; then
      DOCKER_SOCK_PATH="${CONTEXT_HOST#unix://}"
    fi
  fi

  if [[ -n "${DOCKER_SOCK_PATH}" ]] && [[ -e "${DOCKER_SOCK_PATH}" ]]; then
    if DOCKER_GID_VALUE="$(
      stat -c '%g' "${DOCKER_SOCK_PATH}" 2>/dev/null
    )"; then
      export DOCKER_GID="${DOCKER_GID_VALUE}"
    elif DOCKER_GID_VALUE="$(
      stat -f '%g' "${DOCKER_SOCK_PATH}" 2>/dev/null
    )"; then
      export DOCKER_GID="${DOCKER_GID_VALUE}"
    else
      if DOCKER_GID_VALUE="$(stat -c '%g' "${DOCKER_SOCK_PATH}")"; then
        if [[ -n "${DOCKER_GID_VALUE}" ]]; then
          export DOCKER_GID="${DOCKER_GID_VALUE}"
        fi
      fi
    fi
  fi

  # macOS Docker Desktop exposes a socket owned by staff, but the in-container
  # socket group that works for access is conventionally 991.
  if [[ "$(uname -s)" == "Darwin" ]] && [[ "${DOCKER_GID:-}" == "20" ]]; then
    export DOCKER_GID="991"
  fi

  if [[ -z "${DOCKER_GID:-}" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      export DOCKER_GID="991"
    else
      export DOCKER_GID="999"
    fi
  fi
fi

COMPOSE_CMD=(
  docker compose
  -f "$SCRIPT_DIR/compose.yml"
  --project-directory "$SCRIPT_DIR"
)

if [[ "$BUILD_BEFORE_RUN" -eq 1 ]]; then
    if ! MISE_VERSION="$(curl -fsSL https://mise.jdx.dev/VERSION)"; then
        printf '%s\n' \
            'capsule: error: failed to fetch MISE_VERSION' >&2
        exit 1
    fi
    if [[ -z "$MISE_VERSION" ]]; then
        printf '%s\n' \
            'capsule: error: fetched empty MISE_VERSION' >&2
        exit 1
    fi
    "${COMPOSE_CMD[@]}" build --build-arg "MISE_VERSION=${MISE_VERSION}" cli
fi

if [[ "${#RUNTIME_ARGS[@]}" -gt 0 ]]; then
  exec "${COMPOSE_CMD[@]}" run --rm cli "${RUNTIME_ARGS[@]}"
fi

exec "${COMPOSE_CMD[@]}" run --rm cli
