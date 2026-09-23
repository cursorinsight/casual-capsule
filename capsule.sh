#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
  exec "$SCRIPT_DIR/bin/capsule" run "$@"
fi
exec "$SCRIPT_DIR/bin/capsule" "$@"
