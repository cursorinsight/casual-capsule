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
SCRIPT_PATH="$ROOT_DIR/capsule.sh"
EXAMPLE_PROJECT_DIR="$ROOT_DIR/tests/fixtures/example-project"
CUSTOM_CAPSULE_DIR="$ROOT_DIR/tests/fixtures/custom-capsule"
BUILD_DIR="$ROOT_DIR/_build/tests"

mkdir -p "$BUILD_DIR"
TEST_TMPDIR="$(mktemp -d "$BUILD_DIR/suite_e2e.XXXXXX")"
LOG_FILE="$TEST_TMPDIR/suite_e2e.log"
: >"$LOG_FILE"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SKIP_REASONS=()
PASS_MARK="."
SKIP_MARK="s"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  PASS_MARK=$'\033[32m.\033[0m'
  SKIP_MARK=$'\033[33ms\033[0m'
fi

# Return the current UTC time in an ISO 8601-like format.
timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Append a single timestamped message to the suite logfile.
log_message() {
  printf '%s %s\n' "$(timestamp)" "$*" >>"$LOG_FILE"
}

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

# Record a failed assertion and print it to stderr.
fail() {
  log_message "FAIL: $1"
  printf '\nFAIL: %s\n' "$1" >&2
  printf 'FAIL: see e2e log: %s\n' "$LOG_FILE" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '%s\n' \
      'FAIL: in GitHub Actions, download the uploaded e2e log artifact.' >&2
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Record a passing assertion and print it to stdout.
pass() {
  log_message "PASS: $1"
  printf '%s' "$PASS_MARK"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# Record a skipped assertion and print it to stdout.
skip() {
  local reason="$1"
  local recorded=""

  log_message "SKIP: $1"
  printf '%s' "$SKIP_MARK"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  for recorded in ${SKIP_REASONS[@]+"${SKIP_REASONS[@]}"}; do
    [[ "$recorded" == "$reason" ]] && return
  done
  SKIP_REASONS+=("$reason")
}

# Assert that a file contains a fixed string (the "needle").
assert_file_contains() {
  local file="$1"
  local needle="$2"
  local msg="$3"
  if grep -Fq -- "$needle" "$file"; then
    pass "$msg"
  else
    fail "$msg (missing: $needle)"
  fi
}

# Check whether Docker, Compose, and the daemon are available for e2e tests.
require_docker_prereqs() {
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

  return 0
}

# Return success when Capsule's required GitHub secret is available.
require_github_token() {
  if [[ -z "${GITHUB_API_TOKEN:-}" ]]; then
    skip "$1 requires GITHUB_API_TOKEN"
    return 1
  fi

  return 0
}

# Return success when this host can run the Capsule under rootless podman.
require_podman_prereqs() {
  local info=""

  if ! command -v podman >/dev/null 2>&1; then
    skip "$1 requires podman"
    return 1
  fi

  log_message "Checking rootless podman and its id mappings"
  info="$(podman info \
    --format '{{.Host.Security.Rootless}} {{len .Host.IDMappings.UIDMap}}' \
    2>/dev/null || true)"

  case "$info" in
    'true 1')
      skip "$1 requires a sub-id range for this user (uidmap)"
      return 1
      ;;
    'true '*)
      return 0
      ;;
    *)
      skip "$1 requires a usable rootless podman"
      return 1
      ;;
  esac
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
  if ! require_github_token "podman e2e"; then
    return
  fi

  cp \
    "$EXAMPLE_PROJECT_DIR/check-env.sh" \
    "$EXAMPLE_PROJECT_DIR/fixture.txt" \
    "$workspace/"
  printf '%s\n' "$workspace" >"$config_file"

  # The inner engine has to answer, and the workspace has to be writable as
  # the caller: those are the two properties the backend exists for.
  check_cmd='bash ./check-env.sh'
  check_cmd="$check_cmd && touch written-by-capsule"
  check_cmd="$check_cmd && capsule-docker status"
  check_cmd="$check_cmd && docker run --rm alpine:3.20 echo capsule inner ok"

  log_message "Running capsule.sh --runtime podman --build"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_RUNTIME=podman "$3" --build bash -lc "$4"
  ' bash "$workspace" "$config_file" "$SCRIPT_PATH" "$check_cmd"; then
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
  if ! require_github_token "example project e2e"; then
    return
  fi

  printf '%s\n' "$EXAMPLE_PROJECT_DIR" >"$config_file"
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
  if ! require_github_token "custom compose e2e"; then
    return
  fi

  printf '%s\n' "$EXAMPLE_PROJECT_DIR" >"$config_file"
  # shellcheck disable=SC2016
  check_cmd='bash ./check-env.sh && [[ "${CUSTOM_CAPSULE_IMAGE:-}" == "1" ]]'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_COMPOSE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && printf \"custom capsule ok\\n\""

  log_message "Running capsule.sh --build with CAPSULE_CUSTOM_COMPOSE"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_CUSTOM_COMPOSE="$3" \
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
  if ! require_github_token "custom compose build-custom e2e"; then
    return
  fi

  printf '%s\n' "$EXAMPLE_PROJECT_DIR" >"$config_file"
  # shellcheck disable=SC2016
  check_cmd='bash ./check-env.sh && [[ "${CUSTOM_CAPSULE_IMAGE:-}" == "1" ]]'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_COMPOSE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && printf \"custom build-only capsule ok\\n\""

  log_message "Running capsule.sh --build-custom with CAPSULE_CUSTOM_COMPOSE"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" CAPSULE_CUSTOM_COMPOSE="$3" \
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
  log_message "Suite started"
  test_example_project_end_to_end
  test_custom_compose_end_to_end
  test_custom_compose_build_custom_end_to_end
  test_podman_backend_end_to_end

  log_message \
    "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
  printf '\nSummary: %d passed, %d failed, %d skipped\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  if [[ "${#SKIP_REASONS[@]}" -gt 0 ]]; then
    printf 'Skipped:\n'
    printf '  - %s\n' "${SKIP_REASONS[@]}"
  fi
  printf 'E2E log: %s\n' "$LOG_FILE"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
