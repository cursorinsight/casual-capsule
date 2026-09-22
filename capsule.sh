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
readonly DEFAULT_PODMAN_IMAGE="casual-capsule:local"
readonly DEFAULT_PODMAN_HOME_VOLUME="casual-capsule-home"
readonly CAPSULE_INNER_DIR="/var/lib/capsule/inner"
readonly CAPSULE_HOST_SOCKET="/var/lib/capsule/docker.sock"
readonly CAPSULE_SECRET_PATH="/run/secrets/github_api_token"

# Mutable runtime state. main() initializes these before use.
BUILD_MODE=""
BUILD_MODE_FLAG=""
NO_CACHE=0
PRIVATE_HOME=0
RUNTIME_ARGS=()
RUNTIME_OPTS=()
CAPSULE_CUSTOM_COMPOSE="${CAPSULE_CUSTOM_COMPOSE:-}"
CAPSULE_CUSTOM_DIR=""
REMOTE_HOST=""
REMOTE_SSH_DEST=""
REMOTE_SSH_PORT=""
REMOTE_WORKDIR=""
LOCAL_APPROVAL_PATH=""
IN_NESTED_CAPSULE=0
RUNTIME_SELECTION=""
RUNTIME_BACKEND=""
HOST_DOCKER=0
LIST_CAPSULES=0
LAUNCH_OPTION_SEEN=0
PODMAN_RUN_ARGS=()
PODMAN_CONTAINER_NAME=""
PODMAN_SECRET_FILE=""
PODMAN_INFO_OUTPUT=""
CAPSULE_LIST_ROWS=()
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
  RUNTIME_OPTS=()
  CAPSULE_CUSTOM_COMPOSE="${CAPSULE_CUSTOM_COMPOSE:-}"
  CAPSULE_CUSTOM_DIR=""
  REMOTE_HOST=""
  REMOTE_SSH_DEST=""
  REMOTE_SSH_PORT=""
  REMOTE_WORKDIR=""
  set_runtime_selection "${CAPSULE_RUNTIME:-auto}"
  RUNTIME_BACKEND=""
  HOST_DOCKER=0
  LIST_CAPSULES=0
  LAUNCH_OPTION_SEEN=0
  PODMAN_RUN_ARGS=()
  PODMAN_CONTAINER_NAME=""
  PODMAN_SECRET_FILE=""
  PODMAN_INFO_OUTPUT=""
  CAPSULE_LIST_ROWS=()
  BASE_COMPOSE_CMD=()
  COMPOSE_CMD=()
  unset CAPSULE_HOME_MOUNT 2>/dev/null || true
}

usage() {
  cat <<'EOF'
Usage: capsule.sh [options] [--] [command...]

Options:
  -b, --build  Run "docker compose build cli" before runtime.
  -l, --list  List running Capsules and exit.
  -p, --private-home  Bind-mount a per-user home directory.
      --publish HOST[:CONTAINER]  Publish port on host machine. Repeatable.
  -r, --remote HOST[:PORT]:/abs/path  Run on a remote Docker host over SSH.
      With --list, the workdir suffix is optional.
      --runtime podman|docker|auto  Backend to run in (default: auto).
      --host-docker  Bind the host Docker socket into the Capsule.
  -v, --volume HOST:CONTAINER[:OPTIONS]  Bind-mount a host path. Repeatable.
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
  CAPSULE_PUBLISH  Semicolon-separated --publish specs.
  CAPSULE_VOLUME   Semicolon-separated --volume specs.
  CAPSULE_WORKDIR  Workspace directory (default: cwd).
  CAPSULE_CUSTOM_COMPOSE  Optional override compose file.
  CAPSULE_RUNTIME  Backend to run in: auto, podman, or docker.
  CAPSULE_IMAGE    Image tag the podman backend builds and runs.
  CAPSULE_HOME_VOLUME  podman volume mounted at /home/user.
  CAPSULE_INNER_VOLUME  Volume holding the inner engine state.
  CAPSULE_WITH_DOCKERD  Build the image with a real dockerd.
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

  if [[ "$remote_target" =~ ^(.+):(/.*)$ ]]; then
    REMOTE_HOST="${BASH_REMATCH[1]}"
    REMOTE_WORKDIR="${BASH_REMATCH[2]}"
  elif [[ "$remote_target" =~ ^[^:]+$ ]] || \
       [[ "$remote_target" =~ ^[^:]+:[0-9]+$ ]] || \
       [[ "$remote_target" =~ ^\[[^]]+\](:[0-9]+)?$ ]]; then
    REMOTE_HOST="$remote_target"
    REMOTE_WORKDIR=""
  else
    die "$remote_err"
  fi

  if [[ -z "$REMOTE_HOST" ]]; then
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
  elif [[ "$REMOTE_HOST" =~ ^\[([^]]+)\]$ ]]; then
    REMOTE_SSH_DEST="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$REMOTE_WORKDIR" ]] && [[ "$REMOTE_WORKDIR" != /* ]]; then
    die "--remote workdir must be absolute: $REMOTE_WORKDIR"
  fi
}

# Append non-empty semicolon-separated specs from one runtime option env var.
append_runtime_option_specs() {
  local option="$1"
  local specs="$2"
  local spec=""

  while [[ "$specs" == *";"* ]]; do
    spec="${specs%%;*}"
    if [[ -n "$spec" ]]; then
      RUNTIME_OPTS+=("$option" "$spec")
    fi
    specs="${specs#*;}"
  done

  if [[ -n "$specs" ]]; then
    RUNTIME_OPTS+=("$option" "$specs")
  fi
}

# Apply runtime options supplied by environment variables.
append_runtime_option_env() {
  if [[ -n "${CAPSULE_PUBLISH:-}" ]]; then
    append_runtime_option_specs "--publish" "$CAPSULE_PUBLISH"
  fi

  if [[ -n "${CAPSULE_VOLUME:-}" ]]; then
    append_runtime_option_specs "--volume" "$CAPSULE_VOLUME"
  fi
}

# Record the requested runtime backend, rejecting unknown names.
set_runtime_selection() {
  local selection="$1"

  case "$selection" in
    auto|docker|podman)
      RUNTIME_SELECTION="$selection"
      ;;
    *)
      die "unknown runtime: $selection (use podman, docker, or auto)"
      ;;
  esac
}

# Parse CLI flags and collect runtime arguments.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--build)
        LAUNCH_OPTION_SEEN=1
        set_build_mode "all" "$1"
        shift
        ;;
      --build-custom)
        LAUNCH_OPTION_SEEN=1
        set_build_mode "custom" "$1"
        shift
        ;;
      --no-cache)
        LAUNCH_OPTION_SEEN=1
        NO_CACHE=1
        shift
        ;;
      -l|--list)
        LIST_CAPSULES=1
        shift
        ;;
      -p|--private-home)
        LAUNCH_OPTION_SEEN=1
        PRIVATE_HOME=1
        shift
        ;;
      --publish)
        if [[ $# -lt 2 ]] || [[ "${2:-}" == -* ]]; then
          die '--publish requires HOST[:CONTAINER] port parameter'
        fi
        LAUNCH_OPTION_SEEN=1
        RUNTIME_OPTS+=(--publish "$2")
        shift 2
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
      -v|--volume)
        if [[ $# -lt 2 ]] || [[ "${2:-}" == -* ]]; then
          die '--volume requires HOST:CONTAINER mount volume spec'
        fi
        LAUNCH_OPTION_SEEN=1
        RUNTIME_OPTS+=(--volume "$2")
        shift 2
        ;;
      --runtime)
        if [[ $# -lt 2 ]] || [[ "${2:-}" == -* ]]; then
          die '--runtime requires podman, docker, or auto'
        fi
        set_runtime_selection "$2"
        shift 2
        ;;
      --runtime=*)
        set_runtime_selection "${1#--runtime=}"
        shift
        ;;
      --host-docker)
        LAUNCH_OPTION_SEEN=1
        HOST_DOCKER=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        if [[ $# -gt 0 ]]; then
          LAUNCH_OPTION_SEEN=1
        fi
        RUNTIME_ARGS+=("$@")
        break
        ;;
      *)
        LAUNCH_OPTION_SEEN=1
        RUNTIME_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Reject launch-only arguments in list mode and require a workdir for runs.
validate_operation() {
  local remote_err='--remote requires HOST[:PORT]:/absolute/workdir'

  if [[ "$LIST_CAPSULES" -eq 1 ]]; then
    if [[ "$LAUNCH_OPTION_SEEN" -eq 1 ]]; then
      die '--list cannot be combined with launch options or commands'
    fi
    return
  fi

  if [[ -n "$REMOTE_HOST" ]] && [[ -z "$REMOTE_WORKDIR" ]]; then
    die "$remote_err"
  fi
}

# Read one value from the container's configured environment.
container_env_value() {
  local engine="$1"
  local container_id="$2"
  local variable="$3"
  local container_env=""

  container_env="$("$engine" inspect --format \
    '{{range .Config.Env}}{{println .}}{{end}}' \
    "$container_id" 2>/dev/null)" || return 1

  printf '%s\n' "$container_env" | awk -v prefix="${variable}=" '
    index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1)
      exit
    }
  '
}

# Resolve a numeric host user locally or through the configured SSH target.
resolve_host_user() {
  local host_uid="$1"
  local resolved_user=""

  if [[ ! "$host_uid" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$host_uid"
    return
  fi

  if [[ -n "$REMOTE_HOST" ]]; then
    resolved_user="$(run_remote_ssh \
      "id -nu $host_uid 2>/dev/null || true")"
  else
    resolved_user="$(id -nu "$host_uid" 2>/dev/null || true)"
  fi

  printf '%s\n' "${resolved_user:-$host_uid}"
}

# Print the collected tab-separated rows as an aligned table.
print_capsule_list() {
  {
    printf 'TARGET\tRUNTIME\tUSER\tID\tNAME\tUPTIME'
    printf '\tIMAGE\tSTATUS\tPORTS\tHOST_DIR\n'
    if [[ "${#CAPSULE_LIST_ROWS[@]}" -gt 0 ]]; then
      printf '%s\n' \
        ${CAPSULE_LIST_ROWS[@]+"${CAPSULE_LIST_ROWS[@]}"}
    fi
  } | awk -F '\t' '
    {
      rows = NR
      if (NF > columns) columns = NF
      for (column = 1; column <= NF; column++) {
        value[NR, column] = $column
        if (length($column) > width[column]) width[column] = length($column)
      }
    }
    END {
      for (row = 1; row <= rows; row++) {
        for (column = 1; column < columns; column++) {
          printf "%-*s  ", width[column], value[row, column]
        }
        print value[row, columns]
      }
    }
  '
}

# Print running Capsules visible to one container engine.
list_engine_capsules() {
  local engine="$1"
  local target="$2"
  local ps_format=""
  local ps_output=""
  local row=""
  local container_id=""
  local host_workdir=""
  local host_user=""
  local host_uid=""
  local list_row=""

  ps_format='{{.ID}}{{"\t"}}{{.Names}}{{"\t"}}{{.RunningFor}}'
  ps_format="${ps_format}"'{{"\t"}}{{.Image}}{{"\t"}}{{.Status}}'
  ps_format="${ps_format}"'{{"\t"}}{{.Ports}}'

  if ! ps_output="$(
    "$engine" ps --format "$ps_format" 2>&1
  )"; then
    warn "cannot query $engine containers: $ps_output"
    return 1
  fi

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    container_id="${row%%$'\t'*}"
    if ! host_workdir="$(container_env_value \
      "$engine" "$container_id" CAPSULE_HOST_WORKDIR)"; then
      continue
    fi
    [[ -n "$host_workdir" ]] || continue
    host_uid="$(container_env_value \
      "$engine" "$container_id" CAPSULE_UID || true)"
    host_user="$(resolve_host_user "$host_uid")"
    list_row="$target"$'\t'"$engine"$'\t'"${host_user:-unknown}"
    list_row+=$'\t'"$row"$'\t'"$host_workdir"
    CAPSULE_LIST_ROWS+=("$list_row")
  done <<<"$ps_output"
}

# List local Capsules from selected engines, or Docker Capsules remotely.
list_running_capsules() {
  local queried=0
  local engine=""
  local engines=()

  if [[ -n "$REMOTE_HOST" ]]; then
    if [[ "$RUNTIME_SELECTION" == "podman" ]]; then
      warn 'remote listing uses Docker; ignoring --runtime podman'
    fi
    if ! command -v docker >/dev/null 2>&1; then
      die 'docker is required to query a remote host'
    fi
    export DOCKER_HOST="ssh://$REMOTE_HOST"
    list_engine_capsules docker "$REMOTE_HOST" || \
      die "failed to query running Capsules on $REMOTE_HOST"
    print_capsule_list
    return
  fi

  case "$RUNTIME_SELECTION" in
    auto) engines=(docker podman) ;;
    docker) engines=(docker) ;;
    podman) engines=(podman) ;;
  esac

  for engine in "${engines[@]}"; do
    if ! command -v "$engine" >/dev/null 2>&1; then
      if [[ "$RUNTIME_SELECTION" != "auto" ]]; then
        die "$engine is required by --runtime $RUNTIME_SELECTION"
      fi
      continue
    fi
    if list_engine_capsules "$engine" local; then
      queried=1
    elif [[ "$RUNTIME_SELECTION" != "auto" ]]; then
      die "failed to query running Capsules with $engine"
    fi
  done

  if [[ "$queried" -eq 0 ]]; then
    die 'no usable container runtime found'
  fi

  print_capsule_list
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
  ssh "${ssh_args[@]+${ssh_args[@]}}" \
    "$REMOTE_SSH_DEST" "$remote_cmd" 2>/dev/null || true
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

#------------------------------------------------------------------------------
# podman backend
#
# podman runs the Capsule as a rootless container that carries its own
# container engine:
#
#   host -> podman -> capsule -> its own engine -> the project's containers
#
# The Capsule's engine is private to the workspace it was started for, so a
# project brought up inside one Capsule cannot see the host's containers or
# another workspace's. What needs a Docker daemon on the host (--remote over
# ssh://, compose overrides) stays on the Docker backend, as does a host that
# cannot run rootless containers.
#------------------------------------------------------------------------------

# Print the reason podman cannot be launched at all, if any.
podman_launcher_reason() {
  if ! command -v podman >/dev/null 2>&1; then
    printf '%s\n' 'podman is not installed'
  fi
}

# Print the reason a path is unusable from a podman machine, if any. The
# machine shares the user home with its guest, so a workspace outside it has
# no path the VM can resolve.
podman_vm_path_reason() {
  local path="$1"
  local label="$2"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    return
  fi

  if [[ "$path" != "$HOME" ]] && [[ "$path" != "$HOME"/* ]]; then
    printf '%s is outside %s and the podman machine cannot see it\n' \
      "$label" "$HOME"
  fi
}

# Capture how podman sees itself, once, for the checks that read it. One
# call answers both questions that matter: whether it is rootless, and
# whether this user has a sub-id range to map containers into.
capture_podman_info() {
  PODMAN_INFO_OUTPUT="$(
    podman info --format \
      '{{.Host.Security.Rootless}} {{len .Host.IDMappings.UIDMap}}' \
      2>/dev/null
  )" || PODMAN_INFO_OUTPUT=""
}

# Print the reason this host cannot run the Capsule under podman, if any.
podman_host_reason() {
  local rootless=""
  local id_ranges=""

  if [[ -z "$PODMAN_INFO_OUTPUT" ]]; then
    printf '%s\n' 'podman cannot reach a working engine (try: podman info)'
    return
  fi

  read -r rootless id_ranges <<<"$PODMAN_INFO_OUTPUT"

  # A rootful podman would run the Capsule as real root and make keep-id
  # meaningless, which is not the isolation this backend promises.
  if [[ "$rootless" != "true" ]]; then
    printf '%s\n' 'podman is running rootful; the Capsule wants rootless'
    return
  fi

  # A single mapping means no sub-id range, and podman then cannot even
  # unpack an image that chowns a file, let alone keep the caller's id.
  if [[ ! "$id_ranges" =~ ^[0-9]+$ ]] || [[ "$id_ranges" -le 1 ]]; then
    printf '%s\n' 'no sub-id range for this user (install uidmap)'
  fi
}

# Print the reason this invocation needs the Docker backend, if any.
podman_request_reason() {
  if [[ -n "$REMOTE_HOST" ]]; then
    printf '%s\n' '--remote needs a Docker daemon to reach over ssh://'
    return
  fi

  if [[ -n "$CAPSULE_CUSTOM_COMPOSE" ]]; then
    printf '%s\n' 'a custom compose file needs the Docker backend'
  fi
}

# Choose the backend, preferring podman and naming the reason whenever it
# falls back, so the runtime in use is never a surprise.
resolve_runtime_backend() {
  local reason=""
  local launcher_reason=""

  if [[ "$RUNTIME_SELECTION" == "docker" ]]; then
    RUNTIME_BACKEND="docker"
    return
  fi

  launcher_reason="$(podman_launcher_reason)"
  reason="$(podman_request_reason)"

  if [[ -z "$reason" ]]; then
    reason="$launcher_reason"
  fi

  if [[ -z "$reason" ]]; then
    reason="$(podman_vm_path_reason "$CAPSULE_HOST_WORKDIR" 'the workspace')"
  fi

  if [[ -z "$reason" ]]; then
    capture_podman_info
    reason="$(podman_host_reason)"
  fi

  if [[ -z "$reason" ]]; then
    RUNTIME_BACKEND="podman"
    return
  fi

  # A host with no podman installed is the ordinary case under "auto" and
  # stays quiet; every other fallback says why podman was not used.
  if [[ "$RUNTIME_SELECTION" == "podman" ]] || [[ -z "$launcher_reason" ]]; then
    warn "not using podman: ${reason}"
  fi

  RUNTIME_BACKEND="docker"
}

# Return the image tag the podman backend builds and runs.
podman_image_name() {
  printf '%s\n' "${CAPSULE_IMAGE:-$DEFAULT_PODMAN_IMAGE}"
}

# Use the current container path when a nested Capsule selects local podman.
# CAPSULE_HOST_WORKDIR names the outer Docker daemon's filesystem, which the
# podman process inside this Capsule cannot see or bind-mount.
configure_nested_podman_workdir() {
  if [[ "$IN_NESTED_CAPSULE" -eq 1 ]]; then
    CAPSULE_HOST_WORKDIR="$CAPSULE_WORKDIR"
    export CAPSULE_HOST_WORKDIR
  fi
}

# Reduce a path to a short, stable, filesystem-safe token.
path_token() {
  local path="$1"

  printf '%s' "$path" | cksum | cut -d' ' -f1
}

# Return a container name that is readable in "podman ps" and unique per run.
podman_container_name() {
  local workspace_name=""

  workspace_name="$(basename -- "$CAPSULE_HOST_WORKDIR")"
  workspace_name="$(printf '%s' "$workspace_name" | tr -c 'A-Za-z0-9_-' '-')"

  printf 'capsule-%s-%s\n' "${workspace_name:-workspace}" "$$"
}

# Return the volume holding this workspace's inner engine state.
#
# It is keyed on the workspace path, so every project gets its own images,
# volumes and containers, and two projects never share an engine's storage.
podman_inner_volume() {
  local workspace_name=""

  if [[ -n "${CAPSULE_INNER_VOLUME:-}" ]]; then
    printf '%s\n' "$CAPSULE_INNER_VOLUME"
    return
  fi

  workspace_name="$(basename -- "$CAPSULE_HOST_WORKDIR")"
  workspace_name="$(printf '%s' "$workspace_name" | tr -c 'A-Za-z0-9_-' '-')"

  printf 'capsule-inner-%s-%s\n' \
    "${workspace_name:-workspace}" "$(path_token "$CAPSULE_HOST_WORKDIR")"
}

# Write the GitHub token where podman can mount it as the runtime secret the
# entrypoint reads. It lives under the user home because a podman machine
# shares that path with its guest.
configure_podman_secret() {
  local secret_dir="${HOME}/.capsule"

  if [[ -z "${GITHUB_API_TOKEN:-}" ]]; then
    return
  fi

  mkdir -p "$secret_dir"
  chmod 700 "$secret_dir"
  PODMAN_SECRET_FILE="${secret_dir}/github_api_token.$$"
  (
    umask 077
    printf '%s' "$GITHUB_API_TOKEN" >"$PODMAN_SECRET_FILE"
  )
}

# Remove the per-run token file once the container is gone.
cleanup_podman_state() {
  if [[ -n "$PODMAN_SECRET_FILE" ]]; then
    rm -f "$PODMAN_SECRET_FILE"
    PODMAN_SECRET_FILE=""
  fi
}

# Fail early when the local image was never built, because podman would
# otherwise try to pull a tag that exists on no registry.
require_podman_image() {
  local image=""

  image="$(podman_image_name)"
  if [[ -n "${CAPSULE_IMAGE:-}" ]]; then
    return
  fi

  if podman image exists "$image" 2>/dev/null; then
    return
  fi

  die "image ${image} is not built; run: capsule.sh --build"
}

# Build the Capsule image with podman, handing it the token as a build
# secret so it reaches the build without reaching a layer.
run_podman_build() {
  local mise_version="$1"
  local build_args=()

  # Build in Docker format: the OCI format podman defaults to drops
  # the Dockerfile SHELL directive, which would run every RUN step
  # under /bin/sh instead of the bash the image expects.
  build_args=(
    build
    --format docker
    -t "$(podman_image_name)"
    --build-arg "MISE_VERSION=${mise_version}"
    --build-arg "CAPSULE_UID=${CAPSULE_UID}"
    --build-arg "CAPSULE_GID=${CAPSULE_GID}"
  )

  if [[ "$NO_CACHE" -eq 1 ]]; then
    build_args+=(--no-cache)
  fi

  if [[ -n "${MISE_SYSTEM_TOOLS:-}" ]]; then
    build_args+=(--build-arg "MISE_SYSTEM_TOOLS=${MISE_SYSTEM_TOOLS}")
  fi

  if [[ -n "${CAPSULE_WITH_DOCKERD:-}" ]]; then
    build_args+=(--build-arg "CAPSULE_WITH_DOCKERD=${CAPSULE_WITH_DOCKERD}")
  fi

  if [[ -n "${GITHUB_API_TOKEN:-}" ]]; then
    build_args+=(
      --secret "id=github_api_token,env=GITHUB_API_TOKEN"
    )
  fi

  podman "${build_args[@]}" "$SCRIPT_DIR"
}

# Translate the collected --publish/--volume options into podman flags.
append_podman_runtime_options() {
  local index=0
  local option=""
  local value=""

  while [[ "$index" -lt "${#RUNTIME_OPTS[@]}" ]]; do
    option="${RUNTIME_OPTS[$index]}"
    value="${RUNTIME_OPTS[$((index + 1))]}"
    index=$((index + 2))

    case "$option" in
      --publish) PODMAN_RUN_ARGS+=(--publish "$value") ;;
      --volume) PODMAN_RUN_ARGS+=(--volume "$value") ;;
      *) die "unsupported runtime option for podman: $option" ;;
    esac
  done
}

# Bind the host Docker socket, but only when the run asked for it. The point
# of this backend is an engine of the Capsule's own, so reaching the host
# daemon is a deliberate act rather than a default.
append_podman_host_docker() {
  local socket_path=""

  if [[ "$HOST_DOCKER" -ne 1 ]]; then
    return
  fi

  # An explicit endpoint decides. Probing past a DOCKER_HOST the caller set
  # would bind a different daemon than the one they named.
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if [[ "${DOCKER_HOST}" != unix://* ]]; then
      die "--host-docker cannot bind a non-socket DOCKER_HOST: ${DOCKER_HOST}"
    fi
    socket_path="${DOCKER_HOST#unix://}"
  else
    socket_path="$(detect_local_docker_socket_path)"
  fi

  if [[ -z "$socket_path" ]] || [[ ! -e "$socket_path" ]]; then
    die '--host-docker found no Docker socket on this host'
  fi

  PODMAN_RUN_ARGS+=(--volume "${socket_path}:${CAPSULE_HOST_SOCKET}")
}

# Assemble the "podman run" invocation for this run.
#
# The container is privileged, label-disabled and given /dev/fuse because it
# runs an engine of its own: nesting needs to mount a proc and stack image
# layers. Rootless, "privileged" grants only what the calling user already
# has, so the Capsule still cannot exceed its owner on the host.
build_podman_run_args() {
  local home_mount="${CAPSULE_HOME_MOUNT:-}"

  if [[ -z "$home_mount" ]]; then
    home_mount="${CAPSULE_HOME_VOLUME:-$DEFAULT_PODMAN_HOME_VOLUME}"
    home_mount="${home_mount}:/home/user"
  fi

  PODMAN_RUN_ARGS=(
    run --rm
    --name "$PODMAN_CONTAINER_NAME"
    --hostname capsule
    --privileged
    --security-opt label=disable
    --device /dev/fuse
    --user user
    --userns "keep-id:uid=${CAPSULE_UID},gid=${CAPSULE_GID}"
    --workdir "$CAPSULE_CONTAINER_WORKDIR"
    --volume "${CAPSULE_HOST_WORKDIR}:${CAPSULE_CONTAINER_WORKDIR}"
    --volume "$home_mount"
    --volume "$(podman_inner_volume):${CAPSULE_INNER_DIR}"
    --env "CAPSULE_RUNTIME=podman"
    --env "CAPSULE_UID=${CAPSULE_UID}"
    --env "CAPSULE_HOST_WORKDIR=${CAPSULE_HOST_WORKDIR}"
  )

  if [[ -n "$PODMAN_SECRET_FILE" ]]; then
    PODMAN_RUN_ARGS+=(
      --volume "${PODMAN_SECRET_FILE}:${CAPSULE_SECRET_PATH}:ro"
    )
  fi

  if [[ -t 0 ]] && [[ -t 1 ]]; then
    PODMAN_RUN_ARGS+=(-it)
  fi

  append_podman_host_docker
  append_podman_runtime_options

  PODMAN_RUN_ARGS+=("$(podman_image_name)")

  if [[ "${#RUNTIME_ARGS[@]}" -gt 0 ]]; then
    PODMAN_RUN_ARGS+=("${RUNTIME_ARGS[@]}")
  fi
}

# Run the whole podman path: build when asked, then start the Capsule.
run_podman_backend() {
  local mise_version=""
  local exit_code=0

  configure_nested_podman_workdir
  PODMAN_CONTAINER_NAME="$(podman_container_name)"
  configure_podman_secret
  trap cleanup_podman_state EXIT INT TERM

  if [[ "$BUILD_MODE" != "none" ]]; then
    mise_version="$(fetch_mise_version)"
    run_podman_build "$mise_version"
  fi

  require_podman_image
  build_podman_run_args
  podman "${PODMAN_RUN_ARGS[@]}" || exit_code=$?

  cleanup_podman_state
  return "$exit_code"
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
  exec "${COMPOSE_CMD[@]}" run --rm \
    "${RUNTIME_OPTS[@]+${RUNTIME_OPTS[@]}}" \
    cli "${RUNTIME_ARGS[@]+${RUNTIME_ARGS[@]}}"
}

main() {
  local mise_version=""

  initialize_runtime_state
  append_runtime_option_env
  parse_args "$@"
  validate_operation

  if [[ "$LIST_CAPSULES" -eq 1 ]]; then
    list_running_capsules
    return
  fi

  initialize_workdir_state
  initialize_user_ids
  configure_custom_compose
  validate_build_mode
  initialize_capsule_config
  configure_target_mode

  resolve_runtime_backend

  if [[ "$PRIVATE_HOME" -eq 1 ]]; then
    configure_private_home
  fi

  if [[ "$RUNTIME_BACKEND" == "podman" ]]; then
    run_podman_backend
    return
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
