#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
export CAPSULE_WORKDIR="${CAPSULE_WORKDIR:-${CC_WORKDIR:-$(pwd -P)}}"

if [[ -z "${DOCKER_GID:-}" ]]; then
  DOCKER_SOCK_PATH=""
  if [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" == unix://* ]]; then
    DOCKER_SOCK_PATH="${DOCKER_HOST#unix://}"
  elif [[ -e /var/run/docker.sock ]]; then
    DOCKER_SOCK_PATH="/var/run/docker.sock"
  elif command -v docker >/dev/null 2>&1; then
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
      DOCKER_GID_VALUE="$(ls -ln "${DOCKER_SOCK_PATH}" | awk '{print $4}')"
      if [[ -n "${DOCKER_GID_VALUE}" ]]; then
        export DOCKER_GID="${DOCKER_GID_VALUE}"
      fi
    fi
  fi

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

exec docker compose \
  -f "$SCRIPT_DIR/compose.yml" \
  --project-directory "$SCRIPT_DIR" \
  run --rm cli "$@"
