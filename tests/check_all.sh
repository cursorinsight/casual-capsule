#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Run all lint checks.
#-------------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT_DIR"

shopt -s nullglob

dclint_files=(
  compose.y*ml
  tests/fixtures/*/compose.y*ml
)
hadolint_files=(
  Dockerfile
  tests/fixtures/*/Dockerfile
)
shellcheck_files=(
  *.sh
  docker/*.sh
  tests/*.sh
  tests/fixtures/*/*.sh
)

run_docker_linter() {
  local image="$1"
  local entrypoint="$2"  # leave "" to use the image default
  local category="$3"
  shift 3
  local files=("$@")

  local ep_args=()
  if [[ -n "$entrypoint" ]]; then
    ep_args=(--entrypoint "$entrypoint")
  fi

  local abs_files=()
  local f
  for f in "${files[@]}"; do
    abs_files+=("/mnt/$f")
  done

  printf '%s (docker): checking %d %s files\n' \
    "$image" "${#files[@]}" "$category"
  if docker run --rm \
       -v "$ROOT_DIR:/mnt" \
       ${ep_args[@]+"${ep_args[@]}"} \
       "$image" \
       "${abs_files[@]}"; then
    printf 'PASS: %s checks passed.\n' "$category"
    return 0
  fi

  printf 'FAIL: %s checks failed.\n' "$category" >&2
  return 1
}

run_linter() {
  local tool="$1"
  local docker_image="$2"
  local docker_ep="$3"  # entrypoint override; "" for image default
  local category="$4"
  shift 4
  local files=("$@")

  if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'INFO: no %s files; skipping %s.\n' "$category" "$tool"
    return 0
  fi

  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: checking %d files\n' "$tool" "${#files[@]}"
    if "$tool" "${files[@]}"; then
      printf 'PASS: %s checks passed.\n' "$tool"
      return 0
    fi
    printf 'FAIL: %s checks failed.\n' "$tool" >&2
    return 1
  fi

  if [[ -n "$docker_image" ]] \
       && command -v docker >/dev/null 2>&1; then
    run_docker_linter \
      "$docker_image" "$docker_ep" "$category" "${files[@]}"
    return
  fi

  printf 'WARNING: %s not found; skipping %s lint.\n' \
    "$tool" "$category" >&2
  return 0
}

status=0
printf '%s\n' 'Running lint checks...'
run_linter dclint zavoloklom/dclint "" \
  Compose "${dclint_files[@]}" || status=1
run_linter hadolint hadolint/hadolint /bin/hadolint \
  Dockerfile "${hadolint_files[@]}" || status=1
run_linter shellcheck koalaman/shellcheck:stable "" \
  shell "${shellcheck_files[@]}" || status=1

if [[ "$status" -eq 0 ]]; then
  printf '%s\n' 'All available lint checks passed.'
fi

exit "$status"
