#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Shared result reporting for the test suites and checks: pass, fail and skip
# marks, fixed-string and equality assertions, and the summary.
#
# Recording and the summary use only builtins, since check_all.sh runs with
# a minimal PATH. Callers may redefine two hooks after sourcing it:
#
#   harness_record STATUS MESSAGE  called for each PASS, FAIL and SKIP
#   harness_fail_details           prints extra lines after each failure
#
# Setting HARNESS_STRICT_SKIPS=1 turns every skip into a failure.
#-------------------------------------------------------------------------------

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

harness_record() {
  :
}

harness_fail_details() {
  :
}

# Record a failed check and print it to stderr.
fail() {
  harness_record FAIL "$1"
  printf '\nFAIL: %s\n' "$1" >&2
  harness_fail_details
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Record a passing check; the message is optional.
pass() {
  harness_record PASS "${1:-}"
  printf '%s' "$PASS_MARK"
  PASS_COUNT=$((PASS_COUNT + 1))
}

# Record a skipped check, listing each distinct reason once.
skip() {
  local reason="$1"
  local recorded=""

  if [[ "${HARNESS_STRICT_SKIPS:-}" == "1" ]]; then
    fail "$reason"
    return
  fi

  harness_record SKIP "$reason"
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

# Assert that a file does not contain a fixed string.
assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  local msg="$3"
  if grep -Fq -- "$needle" "$file"; then
    fail "$msg (unexpected: $needle)"
  else
    pass "$msg"
  fi
}

# Assert that two strings are equal.
assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$msg"
  else
    fail "$msg (expected=$expected actual=$actual)"
  fi
}

# Print the totals and skip reasons; succeed only when nothing failed.
harness_summary() {
  printf '\nSummary: %d passed, %d failed, %d skipped\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  if [[ "${#SKIP_REASONS[@]}" -gt 0 ]]; then
    printf 'Skipped:\n'
    printf '  - %s\n' "${SKIP_REASONS[@]}"
  fi
  [[ "$FAIL_COUNT" -eq 0 ]]
}
