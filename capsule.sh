#!/usr/bin/env bash
if [[ "${CAPSULE_DEBUG:-}" == "1" ]]; then
  set -x
fi

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
readonly SCRIPT_DIR
readonly CAPSULE_CONTAINER_WORKDIR="/home/workspace"
readonly DEFAULT_CAPSULE_UID="1000"
readonly DEFAULT_CAPSULE_GID="100"
readonly DEFAULT_DOCKER_GID="999"
readonly DEFAULT_DARWIN_DOCKER_GID="991"

# Mutable runtime state. main() initializes these before use.
BUILD_MODE=""
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
LOCAL_APPROVAL_PATH=""
IN_NESTED_CAPSULE=0
BASE_COMPOSE_CMD=()
COMPOSE_CMD=()

# Print a Capsule error and exit.
die() {
  printf 'capsule: error: %s\n' "$*" >&2
  exit 1
}

# Print a Capsule warning.
warn() {
  printf 'capsule: warning: %s\n' "$*" >&2
}

# Remove a trailing slash while preserving "/".
trim_trailing_slash() {
  local path="$1"

  if [[ "$path" != "/" ]]; then
    path="${path%/}"
  fi

  printf '%s\n' "$path"
}

# Join an absolute base path and suffix without mangling root.
join_host_path() {
  local base="$1"
  local suffix="$2"

  if [[ "$base" == "/" ]]; then
    printf '%s\n' "$suffix"
    return
  fi

  printf '%s%s\n' "$base" "$suffix"
}

# Resolve a container path through CAPSULE_HOST_PATH_MAP.
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
      die "invalid CAPSULE_HOST_PATH_MAP entry: $entry"
    fi

    container_prefix="$(trim_trailing_slash "${entry%%=*}")"
    host_prefix="$(trim_trailing_slash "${entry#*=}")"
    if [[ -z "$container_prefix" || -z "$host_prefix" ]]; then
      die "invalid CAPSULE_HOST_PATH_MAP entry: $entry"
    fi

    if [[ "$container_prefix" != /* || "$host_prefix" != /* ]]; then
      die "CAPSULE_HOST_PATH_MAP paths must be absolute: $entry"
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

# Return success when CAPSULE_WORKDIR points inside a Capsule workspace.
workdir_is_capsule_path() {
  [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR" ]] || \
    [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR"/* ]]
}

# Initialize workdir state for host, nested-Capsule, and mapped-container runs.
initialize_workdir_state() {
  local mapped_workdir=""
  local original_host_workdir="${CAPSULE_HOST_WORKDIR:-}"

  export CAPSULE_WORKDIR="${CAPSULE_WORKDIR:-$(pwd -P)}"
  LOCAL_APPROVAL_PATH="$CAPSULE_WORKDIR"
  IN_NESTED_CAPSULE=0

  if [[ -n "$original_host_workdir" ]] && workdir_is_capsule_path; then
    IN_NESTED_CAPSULE=1
  fi

  if [[ -z "$original_host_workdir" ]]; then
    if mapped_workdir="$(resolve_host_path_map "$CAPSULE_WORKDIR")"; then
      export CAPSULE_HOST_WORKDIR="$mapped_workdir"
      LOCAL_APPROVAL_PATH="$mapped_workdir"
    else
      export CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
    fi
    return
  fi

  if [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR" ]]; then
    export CAPSULE_HOST_WORKDIR="$original_host_workdir"
    return
  fi

  if [[ "$CAPSULE_WORKDIR" == "$CAPSULE_CONTAINER_WORKDIR"/* ]]; then
    CAPSULE_HOST_WORKDIR="$(
      printf '%s%s' \
        "$original_host_workdir" \
        "${CAPSULE_WORKDIR#"$CAPSULE_CONTAINER_WORKDIR"}"
    )"
    export CAPSULE_HOST_WORKDIR
    return
  fi

  # A non-Capsule path inside a container needs CAPSULE_HOST_PATH_MAP to
  # resolve back to a daemon-host path. Without that, fall back to the local
  # path and let Docker surface any mount error.
  export CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
}

# Resolve "id -u" or "id -g", with a default fallback.
detect_host_id() {
  local default_value="$1"
  local id_flag="$2"
  local detected_id=""

  if detected_id="$(id "$id_flag" 2>/dev/null)" && [[ -n "$detected_id" ]]; then
    printf '%s\n' "$detected_id"
    return 0
  fi

  printf '%s\n' "$default_value"
  return 1
}

# Resolve CAPSULE_UID and CAPSULE_GID from env, host id, or defaults.
initialize_user_ids() {
  local used_default_ids=0

  if [[ -n "${CAPSULE_UID:-}" ]]; then
    export CAPSULE_UID
  elif CAPSULE_UID="$(detect_host_id "$DEFAULT_CAPSULE_UID" "-u")"; then
    export CAPSULE_UID
  else
    export CAPSULE_UID
    used_default_ids=1
  fi

  if [[ -n "${CAPSULE_GID:-}" ]]; then
    export CAPSULE_GID
  elif CAPSULE_GID="$(detect_host_id "$DEFAULT_CAPSULE_GID" "-g")"; then
    export CAPSULE_GID
  else
    export CAPSULE_GID
    used_default_ids=1
  fi

  if [[ "$used_default_ids" -eq 1 ]]; then
    warn "cannot detect host UID/GID; using defaults" \
      "(${CAPSULE_UID}:${CAPSULE_GID})"
  fi
}

# Reset mutable option state before parsing arguments.
initialize_runtime_state() {
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
  BASE_COMPOSE_CMD=()
  COMPOSE_CMD=()
  unset CAPSULE_HOME_MOUNT 2>/dev/null || true
}

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

  die "$new_flag cannot be combined with $BUILD_MODE_FLAG"
}

# Parse HOST[:PORT]:/abs/path into REMOTE_* globals.
parse_remote_target() {
  local remote_target="$1"
  local remote_err='--remote requires HOST[:PORT]:/absolute/workdir'

  if [[ -n "$REMOTE_HOST" ]]; then
    die '--remote cannot be specified more than once'
  fi

  if [[ ! "$remote_target" =~ ^(.+):(/.*)$ ]]; then
    die "$remote_err"
  fi

  REMOTE_HOST="${BASH_REMATCH[1]}"
  REMOTE_WORKDIR="${BASH_REMATCH[2]}"

  if [[ -z "$REMOTE_HOST" || -z "$REMOTE_WORKDIR" ]]; then
    die "$remote_err"
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
    die "--remote workdir must be absolute: $REMOTE_WORKDIR"
  fi
}

# Parse CLI flags and collect runtime arguments.
parse_args() {
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
      --no-cache)
        NO_CACHE=1
        shift
        ;;
      -p|--private-home)
        PRIVATE_HOME=1
        shift
        ;;
      -r|--remote)
        if [[ $# -lt 2 ]] || [[ "${2:-}" == -* ]]; then
          die '--remote requires HOST[:PORT]:/absolute/workdir'
        fi
        parse_remote_target "$2"
        shift 2
        ;;
      --remote=*)
        parse_remote_target "${1#--remote=}"
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
}

# Validate and normalize CAPSULE_CUSTOM_COMPOSE when configured.
configure_custom_compose() {
  local custom_compose_dir=""

  if [[ -z "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    return
  fi

  if [[ ! -e "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    die "custom compose file not found: $CAPSULE_CUSTOM_COMPOSE"
  fi

  if [[ ! -r "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    die "custom compose file is not readable: $CAPSULE_CUSTOM_COMPOSE"
  fi

  custom_compose_dir="$(
    CDPATH='' cd -- "$(dirname -- "$CAPSULE_CUSTOM_COMPOSE")" && pwd -P
  )"
  CAPSULE_CUSTOM_DIR="$custom_compose_dir"
  CAPSULE_CUSTOM_COMPOSE="$CAPSULE_CUSTOM_DIR/$(basename \
    -- "$CAPSULE_CUSTOM_COMPOSE")"
  export CAPSULE_CUSTOM_COMPOSE CAPSULE_CUSTOM_DIR

  if ! custom_compose_has_cli_image "$CAPSULE_CUSTOM_COMPOSE"; then
    die 'custom compose must define services.cli.image'
  fi
}

# Reject build modes that require configuration not currently present.
validate_build_mode() {
  if [[ "$BUILD_MODE" == "custom" ]] && [[ -z "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    die '--build-custom requires CAPSULE_CUSTOM_COMPOSE'
  fi
}

# Initialize the allowlist file location and its parent directory.
initialize_capsule_config() {
  CAPSULE_CONFIG="${CAPSULE_CONFIG:-"${HOME}/.config/capsule"}"
  mkdir -p "$(dirname -- "$CAPSULE_CONFIG")"
}

# Prompt once before writing a new allowlist entry.
ensure_allowlist_entry() {
  local approval_key="$1"
  local prompt="$2 (y/N)? "
  local key=""

  if grep -Fxqs "$approval_key" "$CAPSULE_CONFIG"; then
    return
  fi

  if [[ ! -t 0 ]]; then
    die "$approval_key not in allowlist; pre-approve in $CAPSULE_CONFIG"
  fi

  read -rs -n 1 -p "$prompt" key
  if [[ $key == 'y' || $key == 'Y' ]]; then
    printf 'y\n' >&2
    printf '%s\n' "$approval_key" >>"$CAPSULE_CONFIG"
    return
  fi

  printf 'n\n' >&2
  exit 1
}

# Return the allowlist key used for --remote approvals.
remote_approval_key() {
  printf 'ssh://%s%s\n' "$REMOTE_HOST" "$REMOTE_WORKDIR"
}

# Require allowlist approval for a local daemon-host workspace path.
require_local_approval() {
  ensure_allowlist_entry \
    "$LOCAL_APPROVAL_PATH" \
    "Allow capsule to run in ${LOCAL_APPROVAL_PATH}"
}

# Require allowlist approval for a remote daemon-host workspace path.
require_remote_approval() {
  ensure_allowlist_entry \
    "$(remote_approval_key)" \
    "Allow capsule to run on ${REMOTE_HOST} with workspace ${REMOTE_WORKDIR}"
}

# Run a helper command over SSH against the configured remote host.
run_remote_ssh() {
  local remote_cmd="$1"
  local ssh_args=()

  if [[ -n "$REMOTE_SSH_PORT" ]]; then
    ssh_args=(-p "$REMOTE_SSH_PORT")
  fi

  # shellcheck disable=SC2029
  ssh "${ssh_args[@]}" "$REMOTE_SSH_DEST" "$remote_cmd" 2>/dev/null || true
}

# Detect the Docker socket GID on the remote host.
detect_remote_docker_gid() {
  local detect_gid_cmd=""

  detect_gid_cmd="stat -c '%g' /var/run/docker.sock 2>/dev/null || "
  detect_gid_cmd="${detect_gid_cmd}stat -f '%g' /var/run/docker.sock "
  detect_gid_cmd="${detect_gid_cmd}2>/dev/null"
  run_remote_ssh "$detect_gid_cmd"
}

# Resolve the remote user's default private-home directory.
detect_remote_home_dir() {
  run_remote_ssh "printf '%s/.capsule-home' \"\$HOME\""
}

# Return the default host path used by --private-home.
default_private_home_dir() {
  local home_dir=""

  home_dir="$(trim_trailing_slash "$HOME")"
  join_host_path "$home_dir" "/.capsule-home"
}

# Resolve the default private home through CAPSULE_HOST_PATH_MAP.
resolve_mapped_private_home_dir() {
  local default_home_dir="$1"

  if resolve_host_path_map "$default_home_dir"; then
    return
  fi

  die '--private-home with CAPSULE_HOST_PATH_MAP requires a mapping for '\
    "$HOME"' or explicit CAPSULE_HOME_HOST_DIR'
}

# Resolve the host path bound to /home/user for --private-home.
configure_private_home() {
  local create_private_home_dir=0
  local default_home_dir=""

  if [[ -z "${CAPSULE_HOME_HOST_DIR:-}" ]]; then
    if [[ -n "$REMOTE_HOST" ]]; then
      CAPSULE_HOME_HOST_DIR="$(detect_remote_home_dir)"
      if [[ -z "$CAPSULE_HOME_HOST_DIR" ]]; then
        die 'failed to resolve remote private home path'
      fi
    elif [[ "$IN_NESTED_CAPSULE" -eq 1 ]]; then
      die '--private-home inside Capsule requires CAPSULE_HOME_HOST_DIR or '\
        'an outer Capsule started with --private-home'
    else
      default_home_dir="$(default_private_home_dir)"
      if [[ -n "${CAPSULE_HOST_PATH_MAP:-}" ]]; then
        CAPSULE_HOME_HOST_DIR="$(
          resolve_mapped_private_home_dir "$default_home_dir"
        )"
      else
        CAPSULE_HOME_HOST_DIR="$default_home_dir"
        create_private_home_dir=1
      fi
    fi
  fi

  if [[ "$CAPSULE_HOME_HOST_DIR" != /* ]]; then
    die "private home path must be absolute: $CAPSULE_HOME_HOST_DIR"
  fi

  if [[ "$create_private_home_dir" -eq 1 ]]; then
    mkdir -p "$CAPSULE_HOME_HOST_DIR"
  fi

  export CAPSULE_HOME_HOST_DIR
  export CAPSULE_HOME_MOUNT="${CAPSULE_HOME_HOST_DIR}:/home/user"
}

# Apply approval and runtime env setup for local or remote Docker daemons.
configure_target_mode() {
  if [[ -z "$REMOTE_HOST" ]]; then
    require_local_approval
    return
  fi

  require_remote_approval
  export DOCKER_HOST="ssh://$REMOTE_HOST"
  export CAPSULE_HOST_WORKDIR="$REMOTE_WORKDIR"
}

# Return the local Docker socket path, if one is discoverable.
detect_local_docker_socket_path() {
  local docker_sock_path=""
  local docker_host_sock_path=""
  local context_host=""

  # Prefer the active Docker socket so the container user can access the
  # daemon through the mounted socket without running as root.
  if [[ -n "${DOCKER_HOST:-}" ]] && [[ "${DOCKER_HOST}" == unix://* ]]; then
    docker_host_sock_path="${DOCKER_HOST#unix://}"
    if [[ -e "$docker_host_sock_path" ]]; then
      docker_sock_path="$docker_host_sock_path"
    fi
  fi

  if [[ -z "$docker_sock_path" ]] && [[ -e /var/run/docker.sock ]]; then
    docker_sock_path="/var/run/docker.sock"
  elif [[ -z "$docker_sock_path" ]] && command -v docker >/dev/null 2>&1; then
    context_host="$(
      docker context inspect \
        --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true
    )"
    if [[ "$context_host" == unix://* ]]; then
      docker_sock_path="${context_host#unix://}"
    fi
  fi

  printf '%s\n' "$docker_sock_path"
}

# Return the gid for a local Unix socket path.
detect_socket_gid() {
  local socket_path="$1"
  local detected_gid=""

  if detected_gid="$(stat -c '%g' "$socket_path" 2>/dev/null)"; then
    printf '%s\n' "$detected_gid"
    return 0
  fi

  if detected_gid="$(stat -f '%g' "$socket_path" 2>/dev/null)"; then
    printf '%s\n' "$detected_gid"
    return 0
  fi

  if detected_gid="$(stat -c '%g' "$socket_path")" && \
    [[ -n "$detected_gid" ]]; then
    printf '%s\n' "$detected_gid"
    return 0
  fi

  return 1
}

# Return the default Docker socket gid for the local platform.
default_local_docker_gid() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s\n' "$DEFAULT_DARWIN_DOCKER_GID"
    return
  fi

  printf '%s\n' "$DEFAULT_DOCKER_GID"
}

# Detect DOCKER_GID for local Docker usage.
detect_local_docker_gid() {
  local socket_path=""
  local detected_gid=""

  socket_path="$(detect_local_docker_socket_path)"
  if [[ -n "$socket_path" ]] && [[ -e "$socket_path" ]]; then
    if detected_gid="$(detect_socket_gid "$socket_path")"; then
      if [[ "$(uname -s)" == "Darwin" ]] && [[ "$detected_gid" == "20" ]]; then
        printf '%s\n' "$DEFAULT_DARWIN_DOCKER_GID"
        return
      fi

      printf '%s\n' "$detected_gid"
      return
    fi
  fi

  default_local_docker_gid
}

# Resolve DOCKER_GID from env, remote Docker, or the local Docker socket.
configure_docker_gid() {
  local detected_gid=""

  if [[ -n "${DOCKER_GID:-}" ]]; then
    export DOCKER_GID
    return
  fi

  if [[ -n "$REMOTE_HOST" ]]; then
    detected_gid="$(detect_remote_docker_gid)"
    if [[ -z "$detected_gid" ]]; then
      detected_gid="$DEFAULT_DOCKER_GID"
    fi
    export DOCKER_GID="$detected_gid"
    return
  fi

  DOCKER_GID="$(detect_local_docker_gid)"
  export DOCKER_GID
}

# Initialize base and merged docker compose command arrays.
initialize_compose_commands() {
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
}

# Fetch the current mise release used by image builds.
fetch_mise_version() {
  local mise_version=""

  if ! mise_version="$(curl -fsSL https://mise.en.dev/VERSION)"; then
    die 'failed to fetch MISE_VERSION'
  fi

  if [[ -z "$mise_version" ]]; then
    die 'fetched empty MISE_VERSION'
  fi

  printf '%s\n' "$mise_version"
}

# Run "docker compose build" with the common MISE_VERSION build arg.
run_compose_build() {
  local mise_version="$1"
  local build_no_cache_args=()
  shift

  if [[ "$NO_CACHE" -eq 1 ]]; then
    build_no_cache_args=(--no-cache)
  fi

  "$@" build \
    ${build_no_cache_args[@]+"${build_no_cache_args[@]}"} \
    --build-arg "MISE_VERSION=${mise_version}" cli
}

# Execute the build steps requested by --build or --build-custom.
run_requested_builds() {
  local mise_version="$1"

  if [[ "$BUILD_MODE" == "all" ]]; then
    run_compose_build "$mise_version" "${BASE_COMPOSE_CMD[@]}"
    if [[ -n "$CAPSULE_CUSTOM_COMPOSE" ]]; then
      run_compose_build "$mise_version" "${COMPOSE_CMD[@]}"
    fi
  fi

  if [[ "$BUILD_MODE" == "custom" ]]; then
    run_compose_build "$mise_version" "${COMPOSE_CMD[@]}"
  fi
}

# Exec the runtime container, preserving any user-supplied command.
run_capsule_runtime() {
  if [[ "${#RUNTIME_ARGS[@]}" -gt 0 ]]; then
    exec "${COMPOSE_CMD[@]}" run --rm cli "${RUNTIME_ARGS[@]}"
  fi

  exec "${COMPOSE_CMD[@]}" run --rm cli
}

main() {
  local mise_version=""

  initialize_workdir_state
  initialize_user_ids
  initialize_runtime_state
  parse_args "$@"
  configure_custom_compose
  validate_build_mode
  initialize_capsule_config
  configure_target_mode

  if [[ "$PRIVATE_HOME" -eq 1 ]]; then
    configure_private_home
  fi

  configure_docker_gid
  initialize_compose_commands

  if [[ "$BUILD_MODE" != "none" ]]; then
    mise_version="$(fetch_mise_version)"
    run_requested_builds "$mise_version"
  fi

  run_capsule_runtime
}

main "$@"
