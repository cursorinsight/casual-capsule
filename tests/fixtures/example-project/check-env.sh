#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Verify that the example project runs inside the expected Capsule workspace
# and setup.
#-------------------------------------------------------------------------------

set -euo pipefail

[[ "$(pwd -P)" == "/home/workspace" ]]
[[ "$(id -un)" == "user" ]]
[[ "${HOME:-}" == "/home/user" ]]
[[ "${USER:-}" == "user" ]]
[[ "${LOGNAME:-}" == "user" ]]

grep -Fxq 'capsule example fixture' fixture.txt

printf 'capsule example ok\n'
