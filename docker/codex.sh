#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Launch Codex without its approval prompts or internal sandbox.
#-------------------------------------------------------------------------------

set -euo pipefail

CODEX_PATH="$0"
if [[ "$CODEX_PATH" != */* ]]; then
  CODEX_PATH="$(command -v -- "$CODEX_PATH")"
fi
CODEX_DIR="$(CDPATH='' cd -- "$(dirname -- "$CODEX_PATH")" && pwd -P)"
readonly CODEX_DIR

exec "$CODEX_DIR/codex-real" \
  --dangerously-bypass-approvals-and-sandbox "$@"
