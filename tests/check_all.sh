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
readonly CAPSULE_CONTAINER_WORKDIR="/home/workspace"
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
  bin/*
  docker/*.sh
  lib/capsule/*.sh
  libexec/capsule/*
  tests/*.sh
  tests/fixtures/*/*.sh
)

PASS_MARK="."
SKIP_MARK="s"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SKIP_REASONS=()

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  PASS_MARK=$'\033[32m.\033[0m'
  SKIP_MARK=$'\033[33ms\033[0m'
fi

pass() {
  printf '%s' "$PASS_MARK"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf '\nFAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

skip() {
  local reason="$1"
  local recorded=""

  printf '%s' "$SKIP_MARK"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  for recorded in ${SKIP_REASONS[@]+"${SKIP_REASONS[@]}"}; do
    [[ "$recorded" == "$reason" ]] && return
  done
  SKIP_REASONS+=("$reason")
}

resolve_docker_mount_root() {
  local root_dir="$1"
  local container_workdir="${CAPSULE_WORKDIR:-$CAPSULE_CONTAINER_WORKDIR}"
  local host_workdir="${CAPSULE_HOST_WORKDIR:-}"

  if [[ -z "$host_workdir" ]]; then
    printf '%s\n' "$root_dir"
    return
  fi

  if [[ "$root_dir" == "$container_workdir" ]]; then
    printf '%s\n' "$host_workdir"
    return
  fi

  if [[ "$root_dir" == "$container_workdir"/* ]]; then
    printf '%s%s\n' \
      "$host_workdir" \
      "${root_dir#"$container_workdir"}"
    return
  fi

  printf '%s\n' "$root_dir"
}

run_docker_linter() {
  local image="$1"
  local entrypoint="$2"  # leave "" to use the image default
  local category="$3"
  shift 3
  local files=("$@")
  local docker_mount_root=""
  local output=""

  local ep_args=()
  if [[ -n "$entrypoint" ]]; then
    ep_args=(--entrypoint "$entrypoint")
  fi

  local abs_files=()
  local f
  for f in "${files[@]}"; do
    abs_files+=("/mnt/$f")
  done

  docker_mount_root="$(resolve_docker_mount_root "$ROOT_DIR")"
  if output="$(
    docker run --rm \
      -v "$docker_mount_root:/mnt" \
      ${ep_args[@]+"${ep_args[@]}"} \
      "$image" \
      "${abs_files[@]}" 2>&1
  )"; then
    pass
    return 0
  fi

  fail "$category checks failed with $image."
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
  fi
  return 1
}

# Return success when a tool is installed and can actually run. A mise shim
# sits on PATH for every tool mise knows about, whether or not a version is
# installed, so "command -v" alone would report a linter that errors out the
# moment it is called.
tool_is_usable() {
  local tool="$1"

  command -v "$tool" >/dev/null 2>&1 \
    && "$tool" --version >/dev/null 2>&1
}

run_linter() {
  local tool="$1"
  local docker_image="$2"
  local docker_ep="$3"  # entrypoint override; "" for image default
  local category="$4"
  shift 4
  local files=("$@")
  local output=""

  if [[ "${#files[@]}" -eq 0 ]]; then
    skip "no $category files; skipping $tool"
    return 0
  fi

  if tool_is_usable "$tool"; then
    if output="$("$tool" "${files[@]}" 2>&1)"; then
      pass
      return 0
    fi
    fail "$tool checks failed."
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" >&2
    fi
    return 1
  fi

  if [[ -n "$docker_image" ]] \
       && command -v docker >/dev/null 2>&1; then
    run_docker_linter \
      "$docker_image" "$docker_ep" "$category" "${files[@]}"
    return
  fi

  skip "$tool unavailable; skipping $category lint"
  return 0
}

status=0
run_linter dclint zavoloklom/dclint "" \
  Compose "${dclint_files[@]}" || status=1
run_linter hadolint hadolint/hadolint /bin/hadolint \
  Dockerfile "${hadolint_files[@]}" || status=1
for shellcheck_file in "${shellcheck_files[@]}"; do
  run_linter shellcheck koalaman/shellcheck:stable "" \
    shell "$shellcheck_file" || status=1
done

printf '\nSummary: %d passed, %d failed, %d skipped\n' \
  "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [[ "${#SKIP_REASONS[@]}" -gt 0 ]]; then
  printf 'Skipped:\n'
  printf '  - %s\n' "${SKIP_REASONS[@]}"
fi

exit "$status"
