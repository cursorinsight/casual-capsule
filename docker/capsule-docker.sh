#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Capsule container engine router and switch.
#
# A Capsule on the podman backend carries its own container engine, private to
# the Capsule and to the workspace it was started for. Nothing runs until a
# container command is issued:
#
#   * `podman system service` on a Docker-compatible socket, the default. It
#     answers the Docker API, so `docker` and `docker compose` drive it, and
#     it starts no daemon of its own.
#   * A real rootless `dockerd`, started only when asked for. Projects that
#     need true Engine behaviour switch to it with `capsule-docker
#     use-dockerd`; the choice then sticks for the life of the Capsule.
#
# Invoked as `docker` this routes a command to the active engine. Invoked as
# `capsule-docker` it manages which engine that is. When the Capsule was
# started with --host-docker, the bound host socket wins over both.
#------------------------------------------------------------------------------

set -euo pipefail

readonly REAL_DOCKER="${CAPSULE_REAL_DOCKER:-/usr/bin/docker}"
readonly HOST_SOCKET="${CAPSULE_HOST_SOCKET:-/var/lib/capsule/docker.sock}"
readonly STATE_DIR="${CAPSULE_ENGINE_DIR:-/tmp/capsule-engine}"
readonly ENGINE_FILE="${STATE_DIR}/engine"
readonly PODMAN_SOCKET="${STATE_DIR}/podman.sock"
readonly PODMAN_LOG="${STATE_DIR}/podman.log"
readonly DOCKERD_SOCKET="${STATE_DIR}/dockerd.sock"
readonly DOCKERD_LOG="${STATE_DIR}/dockerd.log"
readonly START_TIMEOUT=30

# Print a message on stderr, where it cannot corrupt command output.
notice() {
  printf 'capsule: %s\n' "$*" >&2
}

# Print an error and exit.
die() {
  printf 'capsule: error: %s\n' "$*" >&2
  exit 1
}

# Create the per-Capsule state directory, private to this user.
ensure_state_dir() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
}

# Print the engine this Capsule is currently using.
current_engine() {
  if [[ -r "$ENGINE_FILE" ]]; then
    cat "$ENGINE_FILE"
    return
  fi

  printf 'podman\n'
}

# Return success when a socket answers a Docker API ping. Existence alone
# proves nothing -- a stale bind mount or a leftover path would pass it --
# so the answer is what decides.
socket_responds() {
  local socket_path="$1"

  [[ -e "$socket_path" ]] || return 1
  DOCKER_HOST="unix://${socket_path}" "$REAL_DOCKER" version \
    >/dev/null 2>&1
}

# Wait for a socket to answer, or fail after START_TIMEOUT seconds.
wait_for_socket() {
  local socket_path="$1"
  local waited=0

  while [[ "$waited" -lt "$START_TIMEOUT" ]]; do
    if socket_responds "$socket_path"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  return 1
}

# Start the Podman API service unless it is already answering.
start_podman_service() {
  ensure_state_dir

  if socket_responds "$PODMAN_SOCKET"; then
    return
  fi

  notice 'starting podman API socket (first use)...'
  rm -f "$PODMAN_SOCKET"
  podman system service --time=0 "unix://${PODMAN_SOCKET}" \
    >"$PODMAN_LOG" 2>&1 &

  if ! wait_for_socket "$PODMAN_SOCKET"; then
    notice "podman API socket did not start; see ${PODMAN_LOG}"
    die 'no container engine available'
  fi
}

# Start the rootless Docker daemon unless it is already answering.
start_dockerd() {
  ensure_state_dir

  if socket_responds "$DOCKERD_SOCKET"; then
    return
  fi

  if ! command -v dockerd-rootless.sh >/dev/null 2>&1; then
    die 'this image has no dockerd; rebuild with CAPSULE_WITH_DOCKERD=1'
  fi

  notice 'starting docker daemon (first use)...'
  rm -f "$DOCKERD_SOCKET"
  XDG_RUNTIME_DIR="$STATE_DIR" \
    dockerd-rootless.sh --host="unix://${DOCKERD_SOCKET}" \
    >"$DOCKERD_LOG" 2>&1 &

  if ! wait_for_socket "$DOCKERD_SOCKET"; then
    notice "docker daemon did not start; see ${DOCKERD_LOG}"
    die 'dockerd unavailable'
  fi
}

# Print the socket of the active engine, starting it when needed.
ensure_engine_socket() {
  local engine=""

  # A bound host socket wins, but only when it answers: a stale mount
  # should fall through to the Capsule's own engine, not fail every
  # command.
  if socket_responds "$HOST_SOCKET"; then
    printf '%s\n' "$HOST_SOCKET"
    return
  fi

  engine="$(current_engine)"
  case "$engine" in
    dockerd)
      start_dockerd
      printf '%s\n' "$DOCKERD_SOCKET"
      ;;
    *)
      start_podman_service
      printf '%s\n' "$PODMAN_SOCKET"
      ;;
  esac
}

# Route a docker command to the active engine.
run_docker() {
  local socket_path=""

  socket_path="$(ensure_engine_socket)"
  export DOCKER_HOST="unix://${socket_path}"
  exec "$REAL_DOCKER" "$@"
}

# Switch this Capsule to the real Docker daemon and start it.
cmd_use_dockerd() {
  ensure_state_dir
  start_dockerd
  printf 'dockerd\n' >"$ENGINE_FILE"
  notice 'engine: dockerd'
}

# Switch this Capsule back to the Podman API socket.
cmd_use_podman() {
  ensure_state_dir
  printf 'podman\n' >"$ENGINE_FILE"
  notice 'engine: podman'
}

# Report which engine is selected and what is actually running.
cmd_status() {
  local engine=""
  local podman_state="stopped"
  local dockerd_state="stopped"

  engine="$(current_engine)"
  socket_responds "$PODMAN_SOCKET" && podman_state="running"
  socket_responds "$DOCKERD_SOCKET" && dockerd_state="running"

  if socket_responds "$HOST_SOCKET"; then
    printf 'engine: host docker socket (--host-docker)\n'
  else
    printf 'engine: %s\n' "$engine"
  fi

  printf 'podman api socket: %s\n' "$podman_state"
  printf 'dockerd: %s\n' "$dockerd_state"
}

# Stop whatever this Capsule started, leaving the choice in place.
cmd_stop() {
  if socket_responds "$DOCKERD_SOCKET"; then
    pkill -f 'dockerd-rootless' 2>/dev/null || true
  fi

  if socket_responds "$PODMAN_SOCKET"; then
    pkill -f 'podman system service' 2>/dev/null || true
  fi

  rm -f "$PODMAN_SOCKET" "$DOCKERD_SOCKET"
  notice 'engines stopped'
}

usage() {
  cat <<'EOF'
Usage: capsule-docker <command>

Commands:
  use-dockerd  Start the real rootless Docker daemon and route to it.
  use-podman   Route to the Podman API socket (the default).
  status       Show the selected engine and what is running.
  stop         Stop the engines this Capsule started.
EOF
}

main() {
  case "$(basename -- "$0")" in
    docker|docker-compose)
      run_docker "$@"
      ;;
  esac

  case "${1:-}" in
    use-dockerd) cmd_use_dockerd ;;
    use-podman) cmd_use_podman ;;
    status) cmd_status ;;
    stop) cmd_stop ;;
    -h|--help|"") usage ;;
    *) die "unknown command: $1" ;;
  esac
}

main "$@"
