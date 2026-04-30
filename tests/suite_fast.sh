#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Test suite that contain fast test cases.
#
# These test cases use mocking to avoid calling into Docker.
#-------------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT_PATH="$ROOT_DIR/capsule.sh"
COMPOSE_PATH="$ROOT_DIR/compose.yml"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile"
ENTRYPOINT_PATH="$ROOT_DIR/docker/entrypoint.sh"
EXAMPLE_PROJECT_DIR="$ROOT_DIR/tests/fixtures/example-project"

TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

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

make_mock_bin() {
  local dir="$1"
  mkdir -p "$dir"

  cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "context" ]] && [[ "${2:-}" == "inspect" ]]; then
  if [[ -n "${MOCK_CONTEXT_HOST:-}" ]]; then
    printf '%s\n' "$MOCK_CONTEXT_HOST"
  fi
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  {
    printf 'ENV_DOCKER_GID=%s\n' "${DOCKER_GID:-}"
    printf 'ENV_CAPSULE_WORKDIR=%s\n' "${CAPSULE_WORKDIR:-}"
    printf 'ENV_CAPSULE_HOST_WORKDIR=%s\n' "${CAPSULE_HOST_WORKDIR:-}"
    printf 'ENV_CAPSULE_CUSTOM_DIR=%s\n' "${CAPSULE_CUSTOM_DIR:-}"
    printf 'ENV_CAPSULE_UID=%s\n' "${CAPSULE_UID:-}"
    printf 'ENV_CAPSULE_GID=%s\n' "${CAPSULE_GID:-}"
    printf 'ARGS=%s\n' "$*"
  } >>"${MOCK_LOG:?MOCK_LOG is required}"
  exit 0
fi

printf 'unexpected docker call: %s\n' "$*" >&2
exit 1
EOF

  cat >"$dir/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_STAT_FAIL:-}" ]]; then
  exit 1
fi
printf '%s\n' "${MOCK_STAT_GID:-999}"
EOF

  cat >"$dir/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${MOCK_UNAME:-Linux}"
EOF

  cat >"$dir/ls" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_LS_FAIL:-}" ]] || [[ -n "${MOCK_STAT_FAIL:-}" ]]; then
  exit 1
fi
/bin/ls "$@"
EOF

  cat >"$dir/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_ID_FAIL:-}" ]]; then
  exit 1
fi
case "${1:-}" in
  -u) printf '%s\n' "${MOCK_ID_UID:-1000}" ;;
  -g) printf '%s\n' "${MOCK_ID_GID:-100}" ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
printf '2024.1.0\n'
EOF

  chmod +x "$dir/docker" "$dir/stat" "$dir/uname" "$dir/ls" \
    "$dir/id" "$dir/curl"
}

run_capsule() {
  local mock_bin="$1"
  local log_file="$2"
  local cfg_file="${TEST_TMPDIR}/config"
  shift 2
  echo "${CAPSULE_WORKDIR:-$(pwd -P)}" >"${cfg_file}"
  PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" CAPSULE_CONFIG="$cfg_file" \
    "$SCRIPT_PATH" "$@"
}

value_from_log() {
  local key="$1"
  local log_file="$2"
  grep -F "$key=" "$log_file" | tail -n1 | cut -d= -f2-
}

entry_from_log() {
  local key="$1"
  local index="$2"
  local log_file="$3"
  grep -F "$key=" "$log_file" | sed -n "${index}p"
}

# shellcheck disable=SC2016
test_compose_contract() {
  assert_file_contains "$COMPOSE_PATH" \
    'image: casual-capsule:local' \
    "compose pins a stable base image name"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_UID:-1000' \
    "compose uses CAPSULE_UID build-arg default"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_GID:-100' \
    "compose uses CAPSULE_GID build-arg default"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_UID=${CAPSULE_UID:-}' \
    "compose passes CAPSULE_UID to container environment"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_GID=${CAPSULE_GID:-}' \
    "compose passes CAPSULE_GID to container environment"
  assert_file_contains "$COMPOSE_PATH" \
    '${CAPSULE_HOST_WORKDIR:-${CAPSULE_WORKDIR:-${PWD}}}:/home/workspace' \
    "compose mounts the host-visible capsule workdir"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_HOST_WORKDIR=${CAPSULE_HOST_WORKDIR:-}' \
    "compose passes host workdir to nested capsule"
}

test_dockerfile_tooling_contract() {
  assert_file_contains "$DOCKERFILE_PATH" 'shellcheck' \
    "image installs shellcheck for shell linting"
  assert_file_contains "$DOCKERFILE_PATH" 'tree' \
    "image installs tree for directory visualization"
  assert_file_contains "$DOCKERFILE_PATH" 'https://mise.run' \
    "image installs mise"
}

test_dockerfile_uid_gid_contract() {
  assert_file_contains "$DOCKERFILE_PATH" \
    'ARG CAPSULE_UID=1000' \
    "Dockerfile declares CAPSULE_UID build arg"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ARG CAPSULE_GID=100' \
    "Dockerfile declares CAPSULE_GID build arg"
  # shellcheck disable=SC2016
  assert_file_contains "$DOCKERFILE_PATH" \
    'useradd -l -m -u "${CAPSULE_UID}"' \
    "Dockerfile uses CAPSULE_UID in useradd"
  assert_file_contains "$DOCKERFILE_PATH" \
    'COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/' \
    "Dockerfile copies entrypoint script"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' \
    "Dockerfile sets entrypoint for runtime UID/GID"
  assert_file_contains "$DOCKERFILE_PATH" \
    'CMD ["/bin/bash", "-il"]' \
    "Dockerfile uses login shell as default command"
}

test_entrypoint_contract() {
  if ! bash -n "$ENTRYPOINT_PATH"; then
    fail "entrypoint.sh has valid shell syntax"
  else
    pass "entrypoint.sh has valid shell syntax"
  fi
  assert_file_contains "$ENTRYPOINT_PATH" \
    'CAPSULE_UID' \
    "entrypoint reads CAPSULE_UID"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'CAPSULE_GID' \
    "entrypoint reads CAPSULE_GID"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'DOCKER_GID' \
    "entrypoint handles DOCKER_GID group"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'export HOME=' \
    "entrypoint sets HOME before dropping privileges"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'export USER=' \
    "entrypoint sets USER before dropping privileges"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'export LOGNAME=' \
    "entrypoint sets LOGNAME before dropping privileges"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'setpriv' \
    "entrypoint drops privileges via setpriv"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'stat -c' \
    "entrypoint checks home dir ownership for stale volumes"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'exec "$@"' \
    "entrypoint has non-root fast path"
}

test_build_flag_runs_build_then_runtime() {
  local tdir="$TEST_TMPDIR/build-flag"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" --build true

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --build-arg MISE_VERSION=${mise_ver}"
  expected_build="$expected_build cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "build flag runs compose build first"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "build flag still runs compose runtime"
}

# Create a minimal custom compose fixture plus Dockerfile for override tests.
make_custom_compose() {
  local dir="$1"
  local image_name="$2"
  mkdir -p "$dir"

  cat >"$dir/compose.yml" <<EOF
services:
  cli:
    image: ${image_name}
    build:
      context: \${CAPSULE_CUSTOM_DIR}
      dockerfile: \${CAPSULE_CUSTOM_DIR}/Dockerfile
    environment:
      CUSTOM_FLAG: enabled
EOF

  cat >"$dir/Dockerfile" <<'EOF'
FROM casual-capsule:local
EOF
}

test_double_dash_keeps_runtime_flags() {
  local tdir="$TEST_TMPDIR/double-dash"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_args=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" -- --build true

  expected_args="compose -f $COMPOSE_PATH"
  expected_args="$expected_args run --rm cli --build true"

  assert_equals \
    "$expected_args" \
    "$(value_from_log ARGS "$log_file")" \
    "double dash passes build-like flags to runtime command"
}

test_build_flag_without_runtime_args() {
  local tdir="$TEST_TMPDIR/build-no-args"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" -b

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --build-arg MISE_VERSION=${mise_ver}"
  expected_build="$expected_build cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH"
  expected_run="$expected_run run --rm cli"

  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "build flag works without runtime args (build call)"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "build flag works without runtime args (run call)"
}

test_plain_runtime_without_args() {
  local tdir="$TEST_TMPDIR/run-no-args"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_run=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file"

  expected_run="compose -f $COMPOSE_PATH"
  expected_run="$expected_run run --rm cli"
  assert_equals \
    "$expected_run" \
    "$(value_from_log ARGS "$log_file")" \
    "plain runtime works without runtime args"
}

# Verify runtime uses both compose files and exports CAPSULE_CUSTOM_DIR.
test_custom_compose_runtime_uses_merged_config() {
  local tdir="$TEST_TMPDIR/custom-runtime"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local expected_run=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "custom-capsule:local"

  DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" true

  expected_run="compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_run" \
    "$(value_from_log ARGS "$log_file")" \
    "custom compose runtime uses merged config"
  assert_equals \
    "$custom_dir" \
    "$(value_from_log ENV_CAPSULE_CUSTOM_DIR "$log_file")" \
    "custom compose exports CAPSULE_CUSTOM_DIR"
}

# Verify --build runs base build, merged build, then merged runtime.
test_custom_compose_builds_base_then_custom_then_runs() {
  local tdir="$TEST_TMPDIR/custom-build"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local expected_build=""
  local expected_custom_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "python-capsule:local"

  DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" --build true

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --build-arg MISE_VERSION=${mise_ver}"
  expected_build="$expected_build cli"
  expected_custom_build="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_custom_build="$expected_custom_build build --build-arg"
  expected_custom_build="$expected_custom_build MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "custom build first builds the base image"
  assert_equals \
    "$expected_custom_build" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "custom build then builds the merged config"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 3 "$log_file")" \
    "custom build still runs the merged config"
}

# Verify a missing custom compose path fails before any Compose invocation.
test_custom_compose_requires_existing_file() {
  local tdir="$TEST_TMPDIR/custom-missing"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local missing_file="$tdir/missing/compose.yml"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$missing_file" \
    run_capsule "$mock_bin" "$log_file" true 2>"$err_file"; then
    fail "custom compose missing file fails early"
  else
    pass "custom compose missing file fails early"
  fi
  assert_file_contains "$err_file" \
    "custom compose file not found" \
    "custom compose missing file reports a clear error"
}

# Verify an unreadable custom compose file fails validation early.
test_custom_compose_requires_readable_file() {
  local tdir="$TEST_TMPDIR/custom-unreadable"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "hidden-capsule:local"
  chmod 000 "$custom_compose"

  if DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" true 2>"$err_file"; then
    fail "custom compose unreadable file fails early"
  else
    pass "custom compose unreadable file fails early"
  fi
  assert_file_contains "$err_file" \
    "custom compose file is not readable" \
    "custom compose unreadable file reports a clear error"
  chmod 600 "$custom_compose"
}

# Verify the custom compose contract requires services.cli.image.
test_custom_compose_requires_cli_image() {
  local tdir="$TEST_TMPDIR/custom-image"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  mkdir -p "$custom_dir"

  cat >"$custom_compose" <<'EOF'
services:
  cli:
    build:
      context: ${CAPSULE_CUSTOM_DIR}
      dockerfile: ${CAPSULE_CUSTOM_DIR}/Dockerfile
EOF

  if DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" true 2>"$err_file"; then
    fail "custom compose without cli.image fails early"
  else
    pass "custom compose without cli.image fails early"
  fi
  assert_file_contains "$err_file" \
    "custom compose must define services.cli.image" \
    "custom compose without cli.image reports a clear error"
}

test_explicit_docker_gid_passthrough() {
  local tdir="$TEST_TMPDIR/explicit"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=4242 CAPSULE_WORKDIR=/tmp/capsule-workdir \
    run_capsule "$mock_bin" "$log_file" bash -lc 'echo ok'

  assert_equals "4242" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "capsule forwards explicit DOCKER_GID"
  assert_equals "/tmp/capsule-workdir" \
    "$(value_from_log ENV_CAPSULE_WORKDIR "$log_file")" \
    "capsule forwards explicit CAPSULE_WORKDIR"
}

test_uid_gid_autodetect() {
  local tdir="$TEST_TMPDIR/uid-autodetect"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  unset CAPSULE_UID CAPSULE_GID 2>/dev/null || true
  DOCKER_GID=1111 MOCK_ID_UID=501 MOCK_ID_GID=20 \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "501" \
    "$(value_from_log ENV_CAPSULE_UID "$log_file")" \
    "CAPSULE_UID auto-detects from host user"
  assert_equals "20" \
    "$(value_from_log ENV_CAPSULE_GID "$log_file")" \
    "CAPSULE_GID auto-detects from host user"
}

test_uid_gid_fallback_when_id_fails() {
  local tdir="$TEST_TMPDIR/uid-fallback"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  unset CAPSULE_UID CAPSULE_GID 2>/dev/null || true
  DOCKER_GID=1111 MOCK_ID_FAIL=1 \
    run_capsule "$mock_bin" "$log_file" true 2>"$err_file"

  assert_equals "1000" \
    "$(value_from_log ENV_CAPSULE_UID "$log_file")" \
    "CAPSULE_UID falls back to 1000 when id fails"
  assert_equals "100" \
    "$(value_from_log ENV_CAPSULE_GID "$log_file")" \
    "CAPSULE_GID falls back to 100 when id fails"
  assert_file_contains "$err_file" \
    "cannot detect host UID/GID" \
    "fallback emits warning to stderr"
}

test_explicit_uid_gid_passthrough() {
  local tdir="$TEST_TMPDIR/uid-explicit"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 CAPSULE_UID=2000 CAPSULE_GID=2000 \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "2000" \
    "$(value_from_log ENV_CAPSULE_UID "$log_file")" \
    "capsule forwards explicit CAPSULE_UID"
  assert_equals "2000" \
    "$(value_from_log ENV_CAPSULE_GID "$log_file")" \
    "capsule forwards explicit CAPSULE_GID"
}

test_workdir_precedence() {
  local tdir="$TEST_TMPDIR/workdir"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  CAPSULE_WORKDIR=/tmp/capsule-first DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" true
  assert_equals "/tmp/capsule-first" \
    "$(value_from_log ENV_CAPSULE_WORKDIR "$log_file")" \
    "CAPSULE_WORKDIR overrides current directory"

  : >"$log_file"
  local pwd_case="$tdir/pwd-case"
  local expected_pwd_case=""
  mkdir -p "$pwd_case"
  (
    cd "$pwd_case"
    expected_pwd_case="$(pwd -P)"
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
    printf '%s\n' "$expected_pwd_case" >"$tdir/expected_pwd_case"
  )
  expected_pwd_case="$(cat "$tdir/expected_pwd_case")"
  assert_equals \
    "$expected_pwd_case" \
    "$(value_from_log ENV_CAPSULE_WORKDIR "$log_file")" \
    "current directory is fallback when workdir vars are unset"
}

test_host_workdir_defaults_to_current_workdir() {
  local tdir="$TEST_TMPDIR/host-workdir-default"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  (
    unset CAPSULE_HOST_WORKDIR
    cd "$EXAMPLE_PROJECT_DIR"
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
  )

  assert_equals "$EXAMPLE_PROJECT_DIR" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "host capsule uses current workdir as host workdir"
}

test_nested_capsule_uses_host_workdir() {
  local tdir="$TEST_TMPDIR/nested-workdir"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local nested_dir="/home/workspace/project/subdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 \
    CAPSULE_WORKDIR="$nested_dir" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "$nested_dir" \
    "$(value_from_log ENV_CAPSULE_WORKDIR "$log_file")" \
    "nested capsule keeps container-local workdir for approval"
  assert_equals "/host/workspace/project/subdir" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "nested capsule forwards host-visible nested workdir"
}

test_linux_gid_autodetect_from_docker_host() {
  local tdir="$TEST_TMPDIR/linux-detect"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local sock_path="$tdir/docker.sock"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  : >"$sock_path"

  DOCKER_GID="" DOCKER_HOST="unix://$sock_path" MOCK_STAT_GID=5678 \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "5678" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "Linux path auto-detects DOCKER_GID from socket"
}

test_bad_docker_host_falls_back_to_context_socket() {
  local tdir="$TEST_TMPDIR/context-fallback"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local sock_path="$tdir/context.sock"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  : >"$sock_path"

  DOCKER_GID="" DOCKER_HOST="unix://$tdir/missing.sock" \
    MOCK_CONTEXT_HOST="unix://$sock_path" MOCK_STAT_GID=6789 \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "6789" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "capsule ignores unusable DOCKER_HOST and falls back to context"
}

test_macos_staff_gid_override() {
  local tdir="$TEST_TMPDIR/darwin-override"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local sock_path="$tdir/docker.sock"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  : >"$sock_path"

  DOCKER_GID="" DOCKER_HOST="unix://$sock_path" MOCK_UNAME=Darwin \
    MOCK_STAT_GID=20 \
    run_capsule "$mock_bin" "$log_file" true

  assert_equals "991" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "macOS staff gid auto-detect is remapped to 991"
}

test_default_gid_when_detection_fails() {
  local tdir="$TEST_TMPDIR/defaults"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID="" DOCKER_HOST="unix://$tdir/missing.sock" MOCK_STAT_FAIL=1 \
    run_capsule "$mock_bin" "$log_file" true
  assert_equals "999" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "Linux default DOCKER_GID is 999 when detection fails"

  : >"$log_file"
  DOCKER_GID="" DOCKER_HOST="unix://$tdir/missing.sock" MOCK_UNAME=Darwin \
    MOCK_STAT_FAIL=1 run_capsule "$mock_bin" "$log_file" true
  assert_equals "991" "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "macOS default DOCKER_GID is 991 when detection fails"
}

main() {
  if ! bash -n "$SCRIPT_PATH"; then
    fail "capsule.sh has valid shell syntax"
  else
    pass "capsule.sh has valid shell syntax"
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck "$SCRIPT_PATH"; then
      fail "capsule.sh has linting errors"
    else
      pass "capsule.sh is lint free"
    fi
  else
    skip "shellcheck not installed; skipping lint check"
  fi

  test_compose_contract
  test_dockerfile_tooling_contract
  test_dockerfile_uid_gid_contract
  test_entrypoint_contract
  test_build_flag_runs_build_then_runtime
  test_double_dash_keeps_runtime_flags
  test_build_flag_without_runtime_args
  test_plain_runtime_without_args
  test_custom_compose_runtime_uses_merged_config
  test_custom_compose_builds_base_then_custom_then_runs
  test_custom_compose_requires_existing_file
  test_custom_compose_requires_readable_file
  test_custom_compose_requires_cli_image
  test_explicit_docker_gid_passthrough
  test_uid_gid_autodetect
  test_uid_gid_fallback_when_id_fails
  test_explicit_uid_gid_passthrough
  test_workdir_precedence
  test_host_workdir_defaults_to_current_workdir
  test_nested_capsule_uses_host_workdir
  test_linux_gid_autodetect_from_docker_host
  test_bad_docker_host_falls_back_to_context_socket
  test_macos_staff_gid_override
  test_default_gid_when_detection_fails

  printf '\nSummary: %d passed, %d failed, %d skipped\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
