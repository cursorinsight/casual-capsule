#!/usr/bin/env bash
if [[ "${CAPSULE_DEBUG:-}" == "1" ]]; then
  set -x
fi

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

trim_trailing_slash() {
  local path="$1"

  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi

  printf '%s\n' "$path"
}

join_host_path() {
  local base="$1"
  local suffix="$2"

  if [[ "$base" == "/" ]]; then
    printf '%s\n' "$suffix"
    return
  fi

  printf '%s%s\n' "$base" "$suffix"
}

resolve_host_path_map() {
  local path="$1"
  local map_entries=()
  local entry=""
  local container_prefix=""
  local host_prefix=""
  local suffix=""

  if [[ -z "${CAPSULE_HOST_PATH_MAP:-}" ]]; then
    return 1
  fi

  IFS=: read -r -a map_entries <<<"${CAPSULE_HOST_PATH_MAP}"
  for entry in "${map_entries[@]}"; do
    if [[ "$entry" != *=* ]]; then
      printf 'capsule: error: invalid CAPSULE_HOST_PATH_MAP entry: %s\n' \
        "$entry" >&2
      exit 1
    fi

    container_prefix="$(trim_trailing_slash "${entry%%=*}")"
    host_prefix="$(trim_trailing_slash "${entry#*=}")"
    if [[ -z "$container_prefix" || -z "$host_prefix" ]]; then
      printf 'capsule: error: invalid CAPSULE_HOST_PATH_MAP entry: %s\n' \
        "$entry" >&2
      exit 1
    fi

    if [[ "$container_prefix" != /* || "$host_prefix" != /* ]]; then
      printf '%s\n' \
        "capsule: error: CAPSULE_HOST_PATH_MAP paths must be absolute: $entry" \
        >&2
      exit 1
    fi

    if [[ "$path" == "$container_prefix" ]]; then
      printf '%s\n' "$host_prefix"
      return 0
    fi

    if [[ "$container_prefix" == "/" ]]; then
      printf '%s\n' "$(join_host_path "$host_prefix" "$path")"
      return 0
    fi

    if [[ "$path" == "$container_prefix"/* ]]; then
      suffix="${path#"$container_prefix"}"
      printf '%s\n' "$(join_host_path "$host_prefix" "$suffix")"
      return 0
    fi
  done

  return 1
}

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
#             CAPSULE_HOST_WORKDIR is the directory on the Docker daemon host
#             that is mapped to /home/workspace inside the container.
#
#         *   If capsule.sh is running inside some other container,
#             CAPSULE_HOST_PATH_MAP can map container paths back to daemon-host
#             paths.
#
#     -   After the if construct below:
#
#         *   CAPSULE_HOST_WORKDIR will point to the same directory as
#             CAPSULE_WORKDIR, but on the Docker daemon host.
#
# To sum up: the following values all point to the same working directory, but
# in different systems:
#
# *   CAPSULE_HOST_WORKDIR (after the if construct below): The working
#     directory's path on the Docker daemon host.
#
# *   CAPSULE_WORKDIR: The working directory's path on the machine where this
#     capsule.sh is running. This might be on the host machine or in a
#     capsule container. If it's in a container, it will be either
#     /home/workspace or /home/workspace/[...].
#
# *   /home/workspace: The working directory's path in the container started by
#     capsule.sh.
ORIG_CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR:-}"
export CAPSULE_WORKDIR="${CAPSULE_WORKDIR:-$(pwd -P)}"
CAPSULE_CONTAINER_WORKDIR="/home/workspace"
LOCAL_APPROVAL_PATH="$CAPSULE_WORKDIR"
IN_NESTED_CAPSULE=0
_CAPSULE_ID_WARN=0

if [[ -n "$ORIG_CAPSULE_HOST_WORKDIR" ]]; then
  if [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR" ]] || \
    [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR"/* ]]; then
    IN_NESTED_CAPSULE=1
  fi
fi

if [[ -z "${CAPSULE_HOST_WORKDIR:-}" ]]; then
  if CAPSULE_HOST_WORKDIR="$(resolve_host_path_map "$CAPSULE_WORKDIR")"; then
    LOCAL_APPROVAL_PATH="$CAPSULE_HOST_WORKDIR"
    export CAPSULE_HOST_WORKDIR
  else
    export CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
  fi
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
  # A non-Capsule path inside a container needs CAPSULE_HOST_PATH_MAP to resolve
  # back to a daemon-host path. Without that, fall back to the local path and
  # let Docker surface any mount error.
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
BUILD_MODE="none"
BUILD_MODE_FLAG=""
NO_CACHE=0
PRIVATE_HOME=0
RUNTIME_ARGS=()
CAPSULE_CUSTOM_COMPOSE="${CAPSULE_CUSTOM_COMPOSE:-}"
CAPSULE_CUSTOM_DIR=""
REMOTE_HOST=""
REMOTE_SSH_DEST=""
REMOTE_SSH_PORT=""
REMOTE_WORKDIR=""
unset CAPSULE_HOME_MOUNT 2>/dev/null || true

usage() {
  cat <<'EOF'
Usage: capsule.sh [options] [--] [command...]

Options:
  -b, --build  Run "docker compose build cli" before runtime.
  -p, --private-home  Bind-mount a per-user home directory.
  -r, --remote HOST[:PORT]:/abs/path  Run on a remote Docker host over SSH.
      --build-custom  Run the custom compose build before runtime.
      --no-cache  Pass --no-cache to build commands run by this script.
  -h, --help   Show this help message.

Environment:
  CAPSULE_DEBUG    Enable shell xtrace when set to 1.
  CAPSULE_UID      Container user UID (auto-detected).
  CAPSULE_GID      Container user GID (auto-detected).
  DOCKER_GID       Docker socket GID (auto-detected).
  DOCKER_HOST      Docker daemon endpoint. --remote sets ssh://HOST[:PORT].
  CAPSULE_HOME_HOST_DIR  Host path used by --private-home.
  CAPSULE_HOST_PATH_MAP  Colon-separated container=host path prefixes.
  CAPSULE_WORKDIR  Workspace directory (default: cwd).
  CAPSULE_CUSTOM_COMPOSE  Optional override compose file.
EOF
}

# Return success when the custom compose file defines services.cli.image.
#
# This validates the minimum override contract before invoking Compose.
custom_compose_has_cli_image() {
  local compose_file="$1"

  awk '
    /^[[:space:]]*services:[[:space:]]*$/ {
      in_services = 1
      in_cli = 0
      next
    }
    in_services && /^[^[:space:]#]/ {
      in_services = 0
      in_cli = 0
    }
    in_services && /^  [^[:space:]#][^:]*:[[:space:]]*$/ {
      in_cli = ($0 ~ /^  cli:[[:space:]]*$/)
      next
    }
    in_cli && /^    image:[[:space:]]*[^[:space:]#]+/ {
      found = 1
      exit 0
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$compose_file"
}

# Record the selected build mode and reject conflicting build flags.
set_build_mode() {
  local new_mode="$1"
  local new_flag="$2"

  if [[ "$BUILD_MODE" == "none" ]]; then
    BUILD_MODE="$new_mode"
    BUILD_MODE_FLAG="$new_flag"
    return
  fi

  if [[ "$BUILD_MODE" == "$new_mode" ]]; then
    return
  fi

  printf 'capsule: error: %s cannot be combined with %s\n' \
    "$new_flag" "$BUILD_MODE_FLAG" >&2
  exit 1
}

parse_remote_target() {
  local remote_target="$1"
  local remote_err=''

  if [[ -n "$REMOTE_HOST" ]]; then
    printf '%s\n' \
      'capsule: error: --remote cannot be specified more than once' >&2
    exit 1
  fi

  remote_err='capsule: error: --remote requires '
  remote_err="${remote_err}HOST[:PORT]:/absolute/workdir"
  if [[ ! "$remote_target" =~ ^(.+):(/.*)$ ]]; then
    printf '%s\n' "$remote_err" >&2
    exit 1
  fi

  REMOTE_HOST="${BASH_REMATCH[1]}"
  REMOTE_WORKDIR="${BASH_REMATCH[2]}"

  if [[ -z "$REMOTE_HOST" || -z "$REMOTE_WORKDIR" ]]; then
    printf '%s\n' "$remote_err" >&2
    exit 1
  fi

  REMOTE_SSH_DEST="$REMOTE_HOST"
  REMOTE_SSH_PORT=""
  if [[ "$REMOTE_HOST" =~ ^([^:]+):([0-9]+)$ ]]; then
    REMOTE_SSH_DEST="${BASH_REMATCH[1]}"
    REMOTE_SSH_PORT="${BASH_REMATCH[2]}"
  elif [[ "$REMOTE_HOST" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    REMOTE_SSH_DEST="${BASH_REMATCH[1]}"
    REMOTE_SSH_PORT="${BASH_REMATCH[2]}"
  fi

  if [[ "$REMOTE_WORKDIR" != /* ]]; then
    printf 'capsule: error: --remote workdir must be absolute: %s\n' \
      "$REMOTE_WORKDIR" >&2
    exit 1
  fi
}

remote_approval_key() {
  printf 'ssh://%s%s\n' "$REMOTE_HOST" "$REMOTE_WORKDIR"
}

require_remote_approval() {
  local approval_key=""
  local prompt=""

  approval_key="$(remote_approval_key)"
  if grep -Fxqs "$approval_key" "$CAPSULE_CONFIG"; then
    return
  fi

  if [[ ! -t 0 ]]; then
    printf 'capsule: error: %s not in allowlist; ' \
      "$approval_key" >&2
    printf 'pre-approve in %s\n' "$CAPSULE_CONFIG" >&2
    exit 1
  fi

  prompt="Allow capsule to run on ${REMOTE_HOST} with workspace "
  prompt="${prompt}${REMOTE_WORKDIR} (y/N)? "
  read -rs -n 1 -p "$prompt" key
  if [[ $key == 'y' || $key == 'Y' ]]; then
    printf 'y\n' >&2
    printf '%s\n' "$approval_key" >>"$CAPSULE_CONFIG"
    return
  fi

  printf 'n\n' >&2
  exit 1
}

require_local_approval() {
  local prompt=""

  if grep -Fxqs "${LOCAL_APPROVAL_PATH}" "${CAPSULE_CONFIG}"; then
    return
  fi

  if [[ ! -t 0 ]]; then
    printf 'capsule: error: %s not in allowlist; ' \
      "${LOCAL_APPROVAL_PATH}" >&2
    printf 'pre-approve in %s\n' "${CAPSULE_CONFIG}" >&2
    exit 1
  fi

  prompt="Allow capsule to run in ${LOCAL_APPROVAL_PATH} (y/N)? "
  read -rs -n 1 -p "$prompt" key
  if [[ $key == 'y' || $key == 'Y' ]]; then
    printf 'y\n' >&2
    printf '%s\n' "${LOCAL_APPROVAL_PATH}" >>"${CAPSULE_CONFIG}"
    return
  fi

  printf 'n\n' >&2
  exit 1
}

run_remote_ssh() {
  local remote_cmd="$1"
  local ssh_args=()

  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    ssh_args=(-p "$REMOTE_SSH_PORT")
  fi

  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$REMOTE_SSH_DEST" "$remote_cmd" 2>/dev/null || true
}

detect_remote_docker_gid() {
  local detect_gid_cmd=""

  detect_gid_cmd="stat -c '%g' /var/run/docker.sock 2>/dev/null || "
  detect_gid_cmd="${detect_gid_cmd}stat -f '%g' /var/run/docker.sock "
  detect_gid_cmd="${detect_gid_cmd}2>/dev/null"
  run_remote_ssh "$detect_gid_cmd"
}

detect_remote_home_dir() {
  run_remote_ssh "printf '%s/.capsule-home' \"\$HOME\""
}

default_private_home_dir() {
  local home_dir=""

  home_dir="$(trim_trailing_slash "$HOME")"
  join_host_path "$home_dir" "/.capsule-home"
}

configure_private_home() {
  local err_msg=""
  local create_private_home_dir=0
  local default_home_dir=""

  if [[ -z "${CAPSULE_HOME_HOST_DIR:-}" ]]; then
    if [[ -n "$REMOTE_HOST" ]]; then
      CAPSULE_HOME_HOST_DIR="$(detect_remote_home_dir)"
      if [[ -z "$CAPSULE_HOME_HOST_DIR" ]]; then
        printf '%s\n' \
          'capsule: error: failed to resolve remote private home path' >&2
        exit 1
      fi
    elif [[ "$IN_NESTED_CAPSULE" -eq 1 ]]; then
      err_msg='capsule: error: --private-home inside Capsule requires '
      err_msg="${err_msg}CAPSULE_HOME_HOST_DIR or an outer Capsule "
      err_msg="${err_msg}started with --private-home"
      printf '%s\n' "$err_msg" >&2
      exit 1
    else
      default_home_dir="$(default_private_home_dir)"
      if [[ -n "${CAPSULE_HOST_PATH_MAP:-}" ]]; then
        if CAPSULE_HOME_HOST_DIR="$(
          resolve_host_path_map "$default_home_dir"
        )"; then
          :
        else
          err_msg='capsule: error: --private-home with '
          err_msg="${err_msg}CAPSULE_HOST_PATH_MAP requires a mapping for "
          err_msg="${err_msg}${HOME} or explicit CAPSULE_HOME_HOST_DIR"
          printf '%s\n' "$err_msg" >&2
          exit 1
        fi
      else
        CAPSULE_HOME_HOST_DIR="$default_home_dir"
        create_private_home_dir=1
      fi
    fi
  fi

  if [[ "$CAPSULE_HOME_HOST_DIR" != /* ]]; then
    printf 'capsule: error: private home path must be absolute: %s\n' \
      "$CAPSULE_HOME_HOST_DIR" >&2
    exit 1
  fi

  if [[ "$create_private_home_dir" -eq 1 ]]; then
    mkdir -p "$CAPSULE_HOME_HOST_DIR"
  fi

  export CAPSULE_HOME_HOST_DIR
  export CAPSULE_HOME_MOUNT="${CAPSULE_HOME_HOST_DIR}:/home/user"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build)
      set_build_mode "all" "$1"
      shift
      ;;
    --build-custom)
      set_build_mode "custom" "$1"
      shift
      ;;
    -p|--private-home)
      PRIVATE_HOME=1
      shift
      ;;
    -r|--remote)
      if [[ $# -lt 2 ]] || [[ "${2:-}" == -* ]]; then
        printf '%s\n' \
          'capsule: error: --remote requires HOST[:PORT]:/absolute/workdir' \
          >&2
        exit 1
      fi
      parse_remote_target "$2"
      shift 2
      ;;
    --remote=*)
      parse_remote_target "${1#--remote=}"
      shift
      ;;
    --no-cache)
      NO_CACHE=1
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

if [[ -n "$CAPSULE_CUSTOM_COMPOSE" ]]; then
  if [[ ! -e "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    printf 'capsule: error: custom compose file not found: %s\n' \
      "$CAPSULE_CUSTOM_COMPOSE" >&2
    exit 1
  fi
  if [[ ! -r "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    printf 'capsule: error: custom compose file is not readable: %s\n' \
      "$CAPSULE_CUSTOM_COMPOSE" >&2
    exit 1
  fi

  CAPSULE_CUSTOM_DIR="$(
    CDPATH='' cd -- "$(dirname -- "$CAPSULE_CUSTOM_COMPOSE")" && pwd -P
  )"
  CAPSULE_CUSTOM_COMPOSE="$CAPSULE_CUSTOM_DIR/$(basename \
    -- "$CAPSULE_CUSTOM_COMPOSE")"
  export CAPSULE_CUSTOM_COMPOSE CAPSULE_CUSTOM_DIR

  if ! custom_compose_has_cli_image "$CAPSULE_CUSTOM_COMPOSE"; then
    printf '%s\n' \
      'capsule: error: custom compose must define services.cli.image' >&2
    exit 1
  fi
fi

if [[ "$BUILD_MODE" == "custom" ]] && [[ -z "$CAPSULE_CUSTOM_COMPOSE" ]]; then
  printf '%s\n' \
    'capsule: error: --build-custom requires CAPSULE_CUSTOM_COMPOSE' >&2
  exit 1
fi

# Require explicit approval before mounting a host path into the container.
CAPSULE_CONFIG=${CAPSULE_CONFIG:-"${HOME}/.config/capsule"}
mkdir -p "$(dirname "${CAPSULE_CONFIG}")"

if [[ -z "$REMOTE_HOST" ]]; then
  require_local_approval
else
  require_remote_approval
  export DOCKER_HOST="ssh://$REMOTE_HOST"
  export CAPSULE_HOST_WORKDIR="$REMOTE_WORKDIR"
fi

if [[ "$PRIVATE_HOME" -eq 1 ]]; then
  configure_private_home
fi

if [[ -z "${DOCKER_GID:-}" ]]; then
  if [[ -n "$REMOTE_HOST" ]]; then
    DOCKER_GID_VALUE="$(detect_remote_docker_gid)"
    if [[ -n "$DOCKER_GID_VALUE" ]]; then
      export DOCKER_GID="$DOCKER_GID_VALUE"
    else
      export DOCKER_GID="999"
    fi
  else
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
    elif [[ -z "${DOCKER_SOCK_PATH}" ]] && \
      command -v docker >/dev/null 2>&1; then
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

    # macOS Docker Desktop exposes a socket owned by staff, but the
    # in-container socket group that works for access is conventionally 991.
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
fi

BASE_COMPOSE_CMD=(
  docker compose
  -f "$SCRIPT_DIR/compose.yml"
)

COMPOSE_CMD=("${BASE_COMPOSE_CMD[@]}")
if [[ -n "$CAPSULE_CUSTOM_COMPOSE" ]]; then
  COMPOSE_CMD=(
    docker compose
    -f "$SCRIPT_DIR/compose.yml"
    -f "$CAPSULE_CUSTOM_COMPOSE"
  )
fi

if [[ "$BUILD_MODE" != "none" ]]; then
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
fi

BUILD_NO_CACHE_ARGS=()
if [[ "$NO_CACHE" -eq 1 ]]; then
    BUILD_NO_CACHE_ARGS=(--no-cache)
fi

if [[ "$BUILD_MODE" == "all" ]]; then
    "${BASE_COMPOSE_CMD[@]}" build \
      ${BUILD_NO_CACHE_ARGS[@]+"${BUILD_NO_CACHE_ARGS[@]}"} \
      --build-arg "MISE_VERSION=${MISE_VERSION}" cli
    if [[ -n "$CAPSULE_CUSTOM_COMPOSE" ]]; then
      "${COMPOSE_CMD[@]}" build \
        ${BUILD_NO_CACHE_ARGS[@]+"${BUILD_NO_CACHE_ARGS[@]}"} \
        --build-arg "MISE_VERSION=${MISE_VERSION}" cli
    fi
fi

if [[ "$BUILD_MODE" == "custom" ]]; then
    "${COMPOSE_CMD[@]}" build \
      ${BUILD_NO_CACHE_ARGS[@]+"${BUILD_NO_CACHE_ARGS[@]}"} \
      --build-arg "MISE_VERSION=${MISE_VERSION}" cli
fi

if [[ "${#RUNTIME_ARGS[@]}" -gt 0 ]]; then
  exec "${COMPOSE_CMD[@]}" run --rm cli "${RUNTIME_ARGS[@]}"
fi

exec "${COMPOSE_CMD[@]}" run --rm cli
