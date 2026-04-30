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
  printf 'FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Record a passing assertion and print it to stdout.
pass() {
  log_message "PASS: $1"
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# Record a skipped assertion and print it to stdout.
skip() {
  log_message "SKIP: $1"
  printf 'SKIP: %s\n' "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
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

  printf '%s\n' "$EXAMPLE_PROJECT_DIR" >"$config_file"
  printf '%s\n' "$token" >"$token_file"
  check_cmd="bash ./check-env.sh && grep -Fxq '$token' e2e-token.txt"

  log_message "Running capsule.sh --build for the example project"
  # shellcheck disable=SC2016
  if run_logged bash -c '
    unset CAPSULE_WORKDIR
    cd "$1" &&
      CAPSULE_CONFIG="$2" "$3" --build bash -lc "$4"
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

  printf '%s\n' "$EXAMPLE_PROJECT_DIR" >"$config_file"
  check_cmd='bash ./check-env.sh && [[ "${CUSTOM_CAPSULE_IMAGE:-}" == "1" ]]'
  check_cmd="$check_cmd && [[ \"\${CUSTOM_CAPSULE_COMPOSE:-}\" == \"1\" ]]"
  check_cmd="$check_cmd && printf \"custom capsule ok\\n\""

  log_message "Running capsule.sh --build with CAPSULE_CUSTOM_COMPOSE"
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

# Run the suite, print the logfile path, and report the final summary.
main() {
  printf 'E2E log: %s\n' "$LOG_FILE"
  log_message "Suite started"
  test_example_project_end_to_end
  test_custom_compose_end_to_end

  log_message \
    "Summary: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
  printf '\nSummary: %d passed, %d failed, %d skipped\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
