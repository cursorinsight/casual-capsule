#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Run all automatic tests.
#-------------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
FAIL_COUNT=0

run_suite() {
  local suite_name="$1"

  printf 'Running %s\n' "$suite_name"
  if ! "$ROOT_DIR/tests/$suite_name"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

main() {
  run_suite "suite_fast.sh"
  run_suite "suite_e2e.sh"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
