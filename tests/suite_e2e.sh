#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Test suite that runs Capsule and Docker.
#
# These test cases use mocking to avoid calling into Docker.
#-------------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/capsule/podman.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/capsule/apple.sh"
SCRIPT_PATH="$ROOT_DIR/capsule.sh"
EXAMPLE_PROJECT_DIR="$ROOT_DIR/tests/fixtures/example-project"
CUSTOM_CAPSULE_DIR="$ROOT_DIR/tests/fixtures/custom-capsule"
PROFILE_CAPSULE_DIR="$ROOT_DIR/tests/fixtures/profile-capsule"
BUILD_DIR="$ROOT_DIR/_build/tests"
PROFILE_TEST_TOKEN="$(
  printf '%s\n' "$PROFILE_CAPSULE_DIR" | cksum | cut -d' ' -f1
)"
printf -v PROFILE_TEST_TOKEN '%08x' "$PROFILE_TEST_TOKEN"
PROFILE_TEST_IMAGE="${CAPSULE_COMPOSE_PROJECT_NAME:-casual-capsule}"
PROFILE_TEST_IMAGE+="-p-test-profile-${PROFILE_TEST_TOKEN}:local"
PODMAN_PROFILE_BASE="${CAPSULE_IMAGE:-casual-capsule:local}"
PODMAN_PROFILE_BASE_TOKEN="$(
  printf '%s\0' "$PODMAN_PROFILE_BASE" | cksum | cut -d' ' -f1
)"
printf -v PODMAN_PROFILE_BASE_TOKEN '%08x' "$PODMAN_PROFILE_BASE_TOKEN"
PODMAN_PROFILE_TEST_IMAGE="${PROFILE_TEST_IMAGE%:local}"
PODMAN_PROFILE_TEST_IMAGE+="-${PODMAN_PROFILE_BASE_TOKEN}:local"
CONTROLLER_PROFILE_TOKEN="$(
  printf '%s\n' '/controller/repo/tests/fixtures/profile-capsule' | \
    cksum | cut -d' ' -f1
)"
printf -v CONTROLLER_PROFILE_TOKEN '%08x' "$CONTROLLER_PROFILE_TOKEN"
CONTROLLER_PROFILE_IMAGE="casual-capsule-p-test-profile-"
CONTROLLER_PROFILE_IMAGE+="${CONTROLLER_PROFILE_TOKEN}:local"
CUSTOM_TEST_IMAGE="fixture-custom-capsule:local"

mkdir -p "$BUILD_DIR"
TEST_TMPDIR="$(mktemp -d "$BUILD_DIR/suite_e2e.XXXXXX")"
LOG_FILE="$TEST_TMPDIR/suite_e2e.log"
: >"$LOG_FILE"

# shellcheck disable=SC1091
source "$ROOT_DIR/tests/lib/harness.sh"
# Read by skip() in the sourced harness.
# shellcheck disable=SC2034
HARNESS_STRICT_SKIPS="${CAPSULE_E2E_STRICT:-}"

# Return the current UTC time in an ISO 8601-like format.
timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Append a single timestamped message to the suite logfile.
log_message() {
  printf '%s %s\n' "$(timestamp)" "$*" >>"$LOG_FILE"
}

# Remove images built only for this suite.
cleanup_test_images() {
  docker image rm -f "$PROFILE_TEST_IMAGE" >/dev/null 2>&1 || true
  docker image rm -f "$CONTROLLER_PROFILE_IMAGE" \
    >/dev/null 2>&1 || true
  docker image rm -f "$CUSTOM_TEST_IMAGE" >/dev/null 2>&1 || true
  podman image rm -f "$PODMAN_PROFILE_TEST_IMAGE" >/dev/null 2>&1 || true
}

cleanup_test_images
trap cleanup_test_images EXIT

# Prefix streamed command output with timestamps before writing the logfile.
log_stream() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s %s\n' "$(timestamp)" "$line"
  done >>"$LOG_FILE"
}

# Run a command and capture its combined output in the timestamped logfile.
run_logged() {
  "$@" 2>&1 | log_stream
}

# Resolve an approval key or mount source with Capsule's own target logic.
resolve_e2e_path() (
  export CAPSULE_ROOT="$ROOT_DIR"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/lib/capsule/common.sh"
  export CAPSULE_WORKDIR="$2"
  initialize_workdir_state
  configure_docker_target
  case "$1" in
    approval) printf '%s\n' "$LOCAL_APPROVAL_PATH" ;;
    host) printf '%s\n' "$CAPSULE_HOST_WORKDIR" ;;
  esac
)

# Resolve the approval path with Capsule's own workdir logic.
resolve_approval_path() {
  resolve_e2e_path approval "$1"
}

# Return a repository root visible to the daemon running a controller.
resolve_controller_host_root() {
  resolve_e2e_path host "$1"
}

# Write one non-interactive Capsule approval using its daemon-visible path.
write_approval_config() {
  local config_file="$1"
  local path="$2"

  resolve_approval_path "$path" >"$config_file"
}

# Log every result to the suite logfile.
harness_record() {
  log_message "$1: $2"
}

# Point a failure at the logfile that holds the command output.
harness_fail_details() {
  printf 'FAIL: see e2e log: %s\n' "$LOG_FILE" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '%s\n' \
      'FAIL: in GitHub Actions, download the uploaded e2e log artifact.' >&2
  fi
}

# Verify E2E approvals use the same mapped path Capsule checks.
test_approval_path_resolution() {
  local controller_root=""
  local mapped=""
  local nested_root=""

  mapped="$(
    DOCKER_HOST=ssh://capsule-path-test \
    CAPSULE_HOST_WORKDIR='' \
      CAPSULE_HOST_PATH_MAP='/workspace=/var/lib/docker/workspace' \
      resolve_approval_path '/workspace/tests/fixtures/example-project'
  )"
  assert_equals \
    '/var/lib/docker/workspace/tests/fixtures/example-project' \
    "$mapped" \
    "E2E approvals use daemon-visible host paths"

  controller_root="$(
    DOCKER_HOST=ssh://capsule-path-test \
    CAPSULE_HOST_WORKDIR='' \
      CAPSULE_HOST_PATH_MAP='/workspace=/var/lib/docker/workspace' \
      resolve_controller_host_root '/workspace'
  )"
  assert_equals '/var/lib/docker/workspace' "$controller_root" \
    "controller root uses mapped resolution as a fallback"

  nested_root="$(
    DOCKER_HOST=ssh://capsule-path-test \
    CAPSULE_HOST_WORKDIR='/host/workspace' \
      CAPSULE_HOST_PATH_MAP='/home/workspace=/wrong/path' \
      resolve_controller_host_root '/home/workspace'
  )"
  assert_equals '/host/workspace' "$nested_root" \
    "nested controller root preserves the daemon-visible path"
}

# Check whether Docker, Compose, and the daemon are available for e2e tests.
require_docker_prereqs() {
  local endpoint=""
  if ! command -v docker >/dev/null 2>&1; then
    skip "$1 requires docker"
    return 1
  fi

  log_message "Checking docker compose availability"
  if ! docker compose version >/dev/null 2>&1; then
    skip "$1 requires docker compose"
    return 1
  fi

  log_message "Checking docker daemon availability"
  if ! docker info >/dev/null 2>&1; then
    skip "$1 requires a reachable docker daemon"
    return 1
  fi

  if command -v capsule-docker >/dev/null 2>&1; then
    endpoint="$(capsule-docker endpoint 2>/dev/null || true)"
    [[ -z "$endpoint" ]] || log_message "Docker target: $endpoint"
  fi

  return 0
}

# Return success when this host can run the Capsule under rootless podman.
require_podman_prereqs() {
  local info=""
  local reason=""

  if ! command -v podman >/dev/null 2>&1; then
    skip "$1 requires podman"
    return 1
  fi

  log_message "Checking rootless podman and its id mappings"
  info="$(podman_info_summary || true)"
  reason="$(podman_host_reason "$info")"
  if [[ -n "$reason" ]]; then
    skip "$1: $reason"
    return 1
  fi
}

# Verify that the podman backend runs the example project, that the Capsule
# owns its workspace, and that its own engine can run a container. This is
# the one test that exercises the whole chain rather than the argv that
# composes it.
test_podman_backend_end_to_end() {
  local tdir="$TEST_TMPDIR/podman-e2e"
  local config_file="$tdir/config"
  local workspace="$tdir/workspace"
  local check_cmd=""
  mkdir -p "$tdir" "$workspace"
  log_message "Starting test_podman_backend_end_to_end"

  if ! require_podman_prereqs "podman e2e"; then
    return
  fi

  cp \
    "$EXAMPLE_PROJECT_DIR/check-env.sh" \
    "$EXAMPLE_PROJECT_DIR/fixture.txt" \
    "$workspace/"
  write_approval_config "$config_file" "$workspace"

  # The inner engine has to answer, and the workspace has to be writable as
  # the caller: those are the two properties the backend exists for.
  # shellcheck disable=SC2016
  check_cmd='read -r payload && [[ "$payload" == "capsule stdin ok" ]]'
  check_cmd+=' && printf "capsule stdin ok\n" && bash ./check-env.sh'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_IMAGE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_PROFILE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && touch written-by-capsule"
  check_cmd="$check_cmd && capsule-docker status"
  check_cmd="$check_cmd && docker run --rm alpine:3.20 echo capsule inner ok"

  log_message "Running capsule.sh --runtime podman --build"
  # shellcheck disable=SC2016
  if printf 'capsule stdin ok\n' | run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=podman \
      "$3" --build --profile "$4" bash -lc "$5"
  ' bash "$workspace" "$config_file" "$SCRIPT_PATH" \
    "$PROFILE_CAPSULE_DIR" "$check_cmd"; then
    assert_file_contains "$LOG_FILE" \
      "capsule stdin ok" \
      "the Podman-backed Capsule preserves piped stdin end to end"
    assert_file_contains "$LOG_FILE" \
      "capsule inner ok" \
      "the Capsule's own engine runs a container end to end"
  else
    fail "the Capsule's own engine runs a container end to end"
  fi

  if [[ -f "$workspace/written-by-capsule" ]]; then
    pass "the Capsule writes to its workspace as the calling user"
  else
    fail "the Capsule writes to its workspace as the calling user"
  fi
}

# Apple container needs a Mac with its service started, which no CI runner
# provides, so its case runs only when CAPSULE_E2E_APPLE=1 opts in. Without
# that it stays silent, so strict CI runs never count it as a skip.
require_apple_prereqs() {
  local reason=""

  [[ "${CAPSULE_E2E_APPLE:-}" == "1" ]] || return 1
  reason="$(apple_host_reason)"
  if [[ -n "$reason" ]]; then
    skip "$1: $reason"
    return 1
  fi
}

# Verify the Apple container backend on a real Mac: the root entrypoint
# drops to the host user, writes land as that user, git accepts the
# root-looking workspace, and docker fails at once without an engine.
test_apple_backend_end_to_end() {
  local tdir="$TEST_TMPDIR/apple-e2e"
  local config_file="$tdir/config"
  local workspace="$tdir/workspace"
  local check_cmd=""
  local status=0

  if ! require_apple_prereqs "apple e2e"; then
    return
  fi
  mkdir -p "$tdir" "$workspace"
  log_message "Starting test_apple_backend_end_to_end"

  cp \
    "$EXAMPLE_PROJECT_DIR/check-env.sh" \
    "$EXAMPLE_PROJECT_DIR/fixture.txt" \
    "$workspace/"
  write_approval_config "$config_file" "$workspace"

  # shellcheck disable=SC2016
  check_cmd='read -r payload && [[ "$payload" == "capsule stdin ok" ]]'
  check_cmd+=' && printf "capsule stdin ok\n" && bash ./check-env.sh'
  check_cmd+=' && touch written-by-capsule'
  check_cmd+=' && git init -q git-check && git -C git-check status >/dev/null'
  check_cmd+=' && printf "capsule git ok\n"'
  check_cmd+=' && ! docker ps 2>docker-err'
  check_cmd+=' && grep -q "no container engine" docker-err'
  check_cmd+=' && printf "capsule no engine ok\n"'

  log_message "Running capsule.sh --runtime apple --build"
  # shellcheck disable=SC2016
  if printf 'capsule stdin ok\n' | run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=apple \
      "$3" --build bash -lc "$4"
  ' bash "$workspace" "$config_file" "$SCRIPT_PATH" "$check_cmd"; then
    assert_file_contains "$LOG_FILE" "capsule stdin ok" \
      "the Apple Capsule preserves piped stdin end to end"
    assert_file_contains "$LOG_FILE" "capsule example ok" \
      "the Apple Capsule runs as the image user in its workspace"
    assert_file_contains "$LOG_FILE" "capsule git ok" \
      "git accepts the Apple Capsule's root-looking workspace"
    assert_file_contains "$LOG_FILE" "capsule no engine ok" \
      "docker fails at once in the Apple Capsule"
  else
    fail "the Apple Capsule runs end to end"
  fi

  if [[ -f "$workspace/written-by-capsule" ]] && \
    [[ "$(stat -f %u "$workspace/written-by-capsule")" == "$(id -u)" ]]; then
    pass "the Apple Capsule writes to its workspace as the calling user"
  else
    fail "the Apple Capsule writes to its workspace as the calling user"
  fi

  # shellcheck disable=SC2016
  run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=apple "$3" sh -c "exit 7"
  ' bash "$workspace" "$config_file" "$SCRIPT_PATH" || status=$?
  assert_equals 7 "$status" "the Apple Capsule returns its exit status"
}

# Verify profile image and runtime settings through the Docker backend.
test_profile_end_to_end() {
  local tdir="$TEST_TMPDIR/profile-e2e"
  local config_file="$tdir/config"
  mkdir -p "$tdir"
  log_message "Starting test_profile_end_to_end"

  if ! require_docker_prereqs "profile e2e"; then
    return
  fi

  write_approval_config "$config_file" "$EXAMPLE_PROJECT_DIR"
  log_message "Building and running the Docker profile through both selectors"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR CAPSULE_PROFILES
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=docker \
      "$3" build --custom --profile "$4" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=docker \
      "$3" --profile "$4" capsule-profile-sentinel cli &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=docker CAPSULE_PROFILES="$4" \
      "$3" capsule-profile-sentinel env
  ' bash "$EXAMPLE_PROJECT_DIR" "$config_file" "$SCRIPT_PATH" \
    "$PROFILE_CAPSULE_DIR"; then
    assert_file_contains "$LOG_FILE" \
      "profile sentinel cli" \
      "a built Docker profile runs its sentinel through --profile"
    assert_file_contains "$LOG_FILE" \
      "profile sentinel env" \
      "CAPSULE_PROFILES selects the same built Docker profile"
  else
    fail "profiles build and run end to end through Docker"
  fi
}

# Verify an absent generated image fails before Compose creates a container.
test_unbuilt_profile_fails_before_container_creation() {
  local tdir="$TEST_TMPDIR/profile-unbuilt-e2e"
  local profile_dir="$tdir/profile"
  local config_file="$tdir/config"
  local command_log="$tdir/docker-commands"
  local mock_bin="$tdir/bin"
  local real_docker=""
  local token=""
  local image=""
  mkdir -p "$profile_dir" "$mock_bin"
  log_message "Starting test_unbuilt_profile_fails_before_container_creation"

  if ! require_docker_prereqs "unbuilt profile e2e"; then
    return
  fi

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "unbuilt-e2e"

[dockerfile]
content = '''
RUN true
'''
EOF
  write_approval_config "$config_file" "$EXAMPLE_PROJECT_DIR"
  token="$(printf '%s\n' "$profile_dir" | cksum | cut -d' ' -f1)"
  printf -v token '%08x' "$token"
  image="casual-capsule-p-unbuilt-e2e-${token}:local"
  docker image rm -f "$image" >/dev/null 2>&1 || true
  real_docker="$(command -v docker)"
  : >"$command_log"

  cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_COMMAND_LOG:?}"
exec "${REAL_DOCKER:?}" "$@"
EOF
  chmod +x "$mock_bin/docker"

  if run_logged env \
    REAL_DOCKER="$real_docker" DOCKER_COMMAND_LOG="$command_log" \
    PATH="$mock_bin:$PATH" \
    CAPSULE_CONFIG="$config_file" CAPSULE_RUNTIME=docker \
    CAPSULE_WORKDIR="$EXAMPLE_PROJECT_DIR" \
    "$SCRIPT_PATH" --profile "$profile_dir" true; then
    fail "an unbuilt Docker profile is rejected"
  else
    pass "an unbuilt Docker profile is rejected"
  fi
  assert_file_contains "$LOG_FILE" \
    "capsule build --profile $profile_dir --runtime docker" \
    "the unbuilt profile error gives the exact build command"
  assert_file_not_contains "$command_log" 'compose' \
    "an unbuilt profile fails before Compose creates a container"
}

# Run Capsule from a plain controller container against the host daemon.
test_profile_from_docker_controller_container() {
  local host_root=""
  local host_workspace=""
  local host_uid=""
  local host_gid=""
  host_root="$(resolve_controller_host_root "$ROOT_DIR")"
  host_workspace="$host_root/tests/fixtures/example-project"
  mkdir -p "$TEST_TMPDIR/profile-controller-e2e"
  log_message "Starting test_profile_from_docker_controller_container"

  if ! require_docker_prereqs "controller container profile e2e"; then
    return
  fi
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "controller container profile e2e requires /var/run/docker.sock"
    return
  fi
  if ! docker image inspect casual-capsule-cli:latest >/dev/null 2>&1; then
    skip "controller container profile e2e requires the base image"
    return
  fi

  host_uid="$(id -u)"
  host_gid="$(id -g)"
  # shellcheck disable=SC2016
  if run_logged docker run --rm \
    --entrypoint bash \
    --volume "$host_root:/controller/repo:ro" \
    --volume /var/run/docker.sock:/controller/docker.sock \
    --env "CAPSULE_UID=$host_uid" \
    --env "CAPSULE_GID=$host_gid" \
    --env GITHUB_API_TOKEN \
    casual-capsule-cli:latest -c '
      set -euo pipefail
      mkdir -p /tmp/controller-bin
      ln -s /usr/bin/docker /tmp/controller-bin/docker
      export PATH="/tmp/controller-bin:$PATH"
      export DOCKER_HOST=unix:///controller/docker.sock
      export CAPSULE_HOST_PATH_MAP="/controller/repo=$4"
      printf "%s\n" "$3" >/tmp/capsule-approvals
      cd /controller/repo/tests/fixtures/example-project
      CAPSULE_CONFIG=/tmp/capsule-approvals CAPSULE_RUNTIME=docker \
        "$1" --build-custom --profile "$2" \
        capsule-profile-sentinel controller
    ' bash \
    /controller/repo/capsule.sh \
    /controller/repo/tests/fixtures/profile-capsule \
    "$host_workspace" "$host_root"; then
    assert_file_contains "$LOG_FILE" \
      "profile sentinel controller" \
      "a non-Capsule controller runs the selected Docker profile image"
  else
    fail "a non-Capsule controller runs a Docker profile"
  fi
}

# Verify that capsule.sh can run the example project end to end.
test_example_project_end_to_end() {
  local tdir="$TEST_TMPDIR/example-project-e2e"
  local config_file="$tdir/config"
  local token="capsule-e2e-${RANDOM}-$$"
  local token_file="$EXAMPLE_PROJECT_DIR/e2e-token.txt"
  local check_cmd=""
  mkdir -p "$tdir"
  log_message "Starting test_example_project_end_to_end"

  if ! require_docker_prereqs "example project e2e"; then
    return
  fi

  write_approval_config "$config_file" "$EXAMPLE_PROJECT_DIR"
  printf '%s\n' "$token" >"$token_file"
  check_cmd="bash ./check-env.sh && grep -Fxq '$token' e2e-token.txt"

  log_message "Running capsule.sh --build for the example project"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=docker "$3" --build bash -lc "$4"
  ' bash "$EXAMPLE_PROJECT_DIR" "$config_file" "$SCRIPT_PATH" "$check_cmd"; then
    assert_file_contains "$LOG_FILE" \
      "capsule example ok" \
      "example project runs end to end through capsule.sh"
  else
    fail "example project runs end to end through capsule.sh"
  fi
  rm -f "$token_file"
}

# Verify that capsule.sh can run with a custom compose override end to end.
test_custom_compose_end_to_end() {
  local tdir="$TEST_TMPDIR/custom-compose-e2e"
  local config_file="$tdir/config"
  local custom_compose="$CUSTOM_CAPSULE_DIR/compose.yml"
  local check_cmd=""
  mkdir -p "$tdir"
  log_message "Starting test_custom_compose_end_to_end"

  if ! require_docker_prereqs "custom compose e2e"; then
    return
  fi

  write_approval_config "$config_file" "$EXAMPLE_PROJECT_DIR"
  # shellcheck disable=SC2016
  check_cmd='bash ./check-env.sh && [[ "${CUSTOM_CAPSULE_IMAGE:-}" == "1" ]]'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_COMPOSE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && printf \"custom capsule ok\\n\""

  log_message "Running capsule.sh --build with CAPSULE_CUSTOM_COMPOSE"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_CUSTOM_COMPOSE="$3" CAPSULE_RUNTIME=docker \
      "$4" --build bash -lc "$5"
  ' bash "$EXAMPLE_PROJECT_DIR" "$config_file" "$custom_compose" \
    "$SCRIPT_PATH" "$check_cmd"; then
    assert_file_contains "$LOG_FILE" \
      "custom capsule ok" \
      "custom compose runs end to end through capsule.sh"
  else
    fail "custom compose runs end to end through capsule.sh"
  fi
}

# Verify that capsule.sh can rebuild only the custom image end to end.
test_custom_compose_build_custom_end_to_end() {
  local tdir="$TEST_TMPDIR/custom-compose-build-custom-e2e"
  local config_file="$tdir/config"
  local custom_compose="$CUSTOM_CAPSULE_DIR/compose.yml"
  local check_cmd=""
  mkdir -p "$tdir"
  log_message "Starting test_custom_compose_build_custom_end_to_end"

  if ! require_docker_prereqs "custom compose build-custom e2e"; then
    return
  fi

  write_approval_config "$config_file" "$EXAMPLE_PROJECT_DIR"
  # shellcheck disable=SC2016
  check_cmd='bash ./check-env.sh && [[ "${CUSTOM_CAPSULE_IMAGE:-}" == "1" ]]'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_COMPOSE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && printf \"custom build-only capsule ok\\n\""

  log_message "Running capsule.sh --build-custom with CAPSULE_CUSTOM_COMPOSE"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_CUSTOM_COMPOSE="$3" CAPSULE_RUNTIME=docker \
      "$4" --build-custom bash -lc "$5"
  ' bash "$EXAMPLE_PROJECT_DIR" "$config_file" "$custom_compose" \
    "$SCRIPT_PATH" "$check_cmd"; then
    assert_file_contains "$LOG_FILE" \
      "custom build-only capsule ok" \
      "build-custom runs custom compose end to end through capsule.sh"
  else
    fail "build-custom runs custom compose end to end through capsule.sh"
  fi
}

# Run the suite, print the logfile path, and report the final summary.
main() {
  local status=0

  log_message "Suite started"
  test_approval_path_resolution
  test_example_project_end_to_end
  test_custom_compose_end_to_end
  test_custom_compose_build_custom_end_to_end
  test_profile_end_to_end
  test_unbuilt_profile_fails_before_container_creation
  test_profile_from_docker_controller_container
  test_podman_backend_end_to_end
  test_apple_backend_end_to_end
  cleanup_test_images
  trap - EXIT

  log_message \
    "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
  harness_summary || status=1
  printf 'E2E log: %s\n' "$LOG_FILE"
  return "$status"
}

main "$@" </dev/null
