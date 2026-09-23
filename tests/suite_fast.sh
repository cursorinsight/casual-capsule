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
CAPSULE_BIN="$ROOT_DIR/bin/capsule"
CORE_PATH="$ROOT_DIR/lib/capsule/common.sh"
CHECK_ALL_PATH="$ROOT_DIR/tests/check_all.sh"
DOCTOR_PATH="$ROOT_DIR/libexec/capsule/doctor"
COMPOSE_PATH="$ROOT_DIR/compose.yml"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile"
README_PATH="$ROOT_DIR/README.md"
ENTRYPOINT_PATH="$ROOT_DIR/docker/entrypoint.sh"
ROUTER_PATH="$ROOT_DIR/docker/capsule-docker.sh"
STORAGE_CONF_PATH="$ROOT_DIR/docker/storage.conf"
EXAMPLE_PROJECT_DIR="$ROOT_DIR/tests/fixtures/example-project"

unset CAPSULE_CUSTOM_COMPOSE
unset CAPSULE_BUILD
unset CAPSULE_BUILD_CUSTOM
unset CAPSULE_EXTRA_APPROVALS
unset CAPSULE_GID
unset CAPSULE_HOME_HOST_DIR
unset CAPSULE_HOST_PATH_MAP
unset CAPSULE_HOST_DOCKER
unset CAPSULE_HOST_WORKDIR
unset CAPSULE_PUBLISH
unset CAPSULE_NO_CACHE
unset CAPSULE_PRIVATE_HOME
unset CAPSULE_REMOTE
unset CAPSULE_RUNTIME
unset CAPSULE_UID
unset CAPSULE_VOLUME
unset CAPSULE_WORKDIR
unset DOCKER_GID
unset DOCKER_HOST

TEST_TMPDIR="$(mktemp -d)"
# Resolve symlinks so paths match what capsule.sh produces via pwd -P.
# On macOS mktemp -d returns /var/folders/… which resolves to
# /private/var/folders/… — without this the path comparisons fail.
TEST_TMPDIR="$(CDPATH='' cd -- "$TEST_TMPDIR" && pwd -P)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

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

fail() {
  printf '\nFAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf '%s' "$PASS_MARK"
  PASS_COUNT=$((PASS_COUNT + 1))
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

if [[ "${1:-}" == "ps" ]]; then
  printf 'DOCKER_PS_ARGS=%s\n' "$*" \
    >>"${MOCK_LOG:?MOCK_LOG is required}"
  printf 'DOCKER_PS_HOST=%s\n' "${DOCKER_HOST:-}" >>"$MOCK_LOG"
  printf '%s\n' "${MOCK_DOCKER_PS:-}"
  exit "${MOCK_DOCKER_PS_EXIT:-0}"
fi

if [[ "${1:-}" == "inspect" ]]; then
  printf 'DOCKER_INSPECT_ARGS=%s\n' "$*" \
    >>"${MOCK_LOG:?MOCK_LOG is required}"
  printf '%s\n' "${MOCK_DOCKER_INSPECT:-}"
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  {
    printf 'ENV_DOCKER_GID=%s\n' "${DOCKER_GID:-}"
    printf 'ENV_DOCKER_HOST=%s\n' "${DOCKER_HOST:-}"
    printf 'ENV_CAPSULE_HOME_HOST_DIR=%s\n' "${CAPSULE_HOME_HOST_DIR:-}"
    printf 'ENV_CAPSULE_HOME_MOUNT=%s\n' "${CAPSULE_HOME_MOUNT:-}"
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

  cat >"$dir/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
  printf 'SSH_ARGS=%s\n' "$*"
} >>"${MOCK_LOG:?MOCK_LOG is required}"
if [[ -n "${MOCK_SSH_FAIL:-}" ]]; then
  exit 1
fi
if [[ "$*" == *'.capsule-home'* ]]; then
  printf '%s\n' "${MOCK_SSH_HOME_DIR:-${MOCK_SSH_OUTPUT:-}}"
else
  printf '%s\n' "${MOCK_SSH_OUTPUT:-}"
fi
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
  -nu) printf '%s\n' "${MOCK_ID_USER:-user}" ;;
  *) /usr/bin/id "$@" ;;
esac
EOF

  cat >"$dir/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Stand in for the two queries capsule.sh makes before it commits to podman:
# whether the engine answers at all, and how it maps ids.
if [[ "${1:-}" == "info" ]]; then
  if [[ -n "${MOCK_PODMAN_INFO_FAIL:-}" ]]; then
    exit 1
  fi
  printf '%s\n' "${MOCK_PODMAN_INFO:-true 2}"
  exit 0
fi

if [[ "${1:-}" == "ps" ]]; then
  printf 'PODMAN_PS_ARGS=%s\n' "$*" \
    >>"${MOCK_LOG:?MOCK_LOG is required}"
  printf '%s\n' "${MOCK_PODMAN_PS:-}"
  exit "${MOCK_PODMAN_PS_EXIT:-0}"
fi

if [[ "${1:-}" == "inspect" ]]; then
  printf 'PODMAN_INSPECT_ARGS=%s\n' "$*" \
    >>"${MOCK_LOG:?MOCK_LOG is required}"
  printf '%s\n' "${MOCK_PODMAN_INSPECT:-}"
  exit 0
fi

if [[ "${1:-}" == "image" ]] && [[ "${2:-}" == "exists" ]]; then
  exit "${MOCK_PODMAN_NO_IMAGE:-0}"
fi

printf 'PODMAN_ARGS=%s\n' "$*" >>"${MOCK_LOG:?MOCK_LOG is required}"
exit 0
EOF

  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
printf '2024.1.0\n'
EOF

  chmod +x "$dir/docker" "$dir/podman" "$dir/stat" "$dir/uname" "$dir/ls" \
    "$dir/id" "$dir/curl" "$dir/ssh"
}

run_capsule() {
  local mock_bin="$1"
  local log_file="$2"
  local cfg_file="${TEST_TMPDIR}/config"
  shift 2
  printf '%s\n' "${CAPSULE_WORKDIR:-$(pwd -P)}" >"${cfg_file}"
  if [[ -n "${CAPSULE_EXTRA_APPROVALS:-}" ]]; then
    printf '%s\n' "${CAPSULE_EXTRA_APPROVALS}" >>"${cfg_file}"
  fi
  PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_BUILD="${CAPSULE_BUILD-}" \
    CAPSULE_BUILD_CUSTOM="${CAPSULE_BUILD_CUSTOM-}" \
    CAPSULE_HOST_PATH_MAP="${CAPSULE_HOST_PATH_MAP-}" \
    CAPSULE_HOST_DOCKER="${CAPSULE_HOST_DOCKER-}" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    CAPSULE_PUBLISH="${CAPSULE_PUBLISH-}" \
    CAPSULE_NO_CACHE="${CAPSULE_NO_CACHE-}" \
    CAPSULE_PRIVATE_HOME="${CAPSULE_PRIVATE_HOME-}" \
    CAPSULE_REMOTE="${CAPSULE_REMOTE-}" \
    CAPSULE_VOLUME="${CAPSULE_VOLUME-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
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

test_command_layout() {
  local command=""
  local help_file="$TEST_TMPDIR/command-help"

  if [[ -x "$CAPSULE_BIN" ]]; then
    pass "bin/capsule is executable"
  else
    fail "bin/capsule is executable"
  fi
  for command in run build list doctor completion; do
    if [[ -x "$ROOT_DIR/libexec/capsule/$command" ]]; then
      pass "capsule $command has an executable implementation"
    else
      fail "capsule $command has an executable implementation"
    fi
  done
  assert_file_contains "$SCRIPT_PATH" 'bin/capsule' \
    "capsule.sh delegates to bin/capsule"
  "$CAPSULE_BIN" --help >"$help_file"
  assert_file_contains "$help_file" 'capsule <command>' \
    "bin/capsule help describes subcommands"
  "$CAPSULE_BIN" dr --help >"$help_file"
  assert_file_contains "$help_file" 'Usage: capsule doctor' \
    "capsule dr aliases the doctor command"
  if CAPSULE_PRIVATE_HOME=maybe "$CAPSULE_BIN" list --help \
    >"$help_file"; then
    pass "list ignores unrelated run environment options"
  else
    fail "list ignores unrelated run environment options"
  fi
  "$SCRIPT_PATH" --help >"$help_file"
  assert_file_contains "$help_file" 'capsule run' \
    "capsule.sh keeps legacy run help"
  if [[ ! -e "$ROOT_DIR/capsule-doctor.sh" ]]; then
    pass "the legacy capsule-doctor.sh entry point is removed"
  else
    fail "the legacy capsule-doctor.sh entry point is removed"
  fi
}

test_completion_subcommand() {
  local tdir="$TEST_TMPDIR/completion"
  local output_file="$tdir/output"
  local err_file="$tdir/err"
  local shell=""
  local marker=""
  mkdir -p "$tdir"

  for shell in bash zsh fish; do
    case "$shell" in
      bash) marker='complete -o bashdefault' ;;
      zsh) marker='#compdef capsule' ;;
      fish) marker='complete -c capsule' ;;
    esac
    "$CAPSULE_BIN" completion "$shell" >"$output_file"
    assert_file_contains "$output_file" "$marker" \
      "completion generates $shell definitions"
    if [[ "$shell" == "bash" ]]; then
      if bash -n "$output_file"; then
        pass "generated Bash completion has valid syntax"
      else
        fail "generated Bash completion has valid syntax"
      fi
    fi
    if [[ "$shell" == "zsh" ]]; then
      assert_file_contains "$output_file" '_capsule_run_arguments()' \
        "Zsh completion defines default-run option candidates"
      assert_file_contains "$output_file" 'words[2]=()' \
        "Zsh completion removes the subcommand from argument context"
      assert_file_contains "$output_file" \
        'run|build|list|doctor|dr|completion)' \
        "Zsh completion shifts only known subcommands"
      assert_file_contains "$output_file" "'1:shell:(bash zsh fish)'" \
        "Zsh completion offers shells after the completion subcommand"
      assert_file_contains "$output_file" \
        '*)
      _capsule_run_arguments' \
        "Zsh completion treats an omitted subcommand as run"
    fi
    if [[ "$shell" == "fish" ]]; then
      assert_file_contains "$output_file" \
        'function __fish_capsule_using_run' \
        "Fish completion defines default-run detection"
      # shellcheck disable=SC2016
      assert_file_contains "$output_file" \
        'not contains -- $words[2] build list doctor dr completion' \
        "Fish completion recognizes omitted run subcommands"
      assert_file_contains "$output_file" \
        "-n '__fish_capsule_using_run' -s b -l build" \
        "Fish completion offers default-run options"
    fi
  done

  if "$CAPSULE_BIN" completion >"$output_file" 2>"$err_file"; then
    fail "completion requires a shell"
  else
    pass "completion requires a shell"
  fi
  assert_file_contains "$err_file" 'shell is required' \
    "completion names its missing argument"

  if "$CAPSULE_BIN" completion tcsh >"$output_file" 2>"$err_file"; then
    fail "completion rejects unsupported shells"
  else
    pass "completion rejects unsupported shells"
  fi
  assert_file_contains "$err_file" 'unsupported shell: tcsh' \
    "completion names an unsupported shell"

  if "$CAPSULE_BIN" completion bash extra \
    >"$output_file" 2>"$err_file"; then
    fail "completion rejects extra arguments"
  else
    pass "completion rejects extra arguments"
  fi
  assert_file_contains "$err_file" 'completion accepts one shell' \
    "completion explains its argument count"
}

# shellcheck disable=SC2016
test_compose_contract() {
  assert_file_contains "$COMPOSE_PATH" \
    'name: ${CAPSULE_COMPOSE_PROJECT_NAME:-casual-capsule}' \
    "compose uses a configurable project name with a stable default"
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
    '${CAPSULE_HOME_MOUNT:-home:/home/user}' \
    "compose allows the home mount to be overridden"
  assert_file_contains "$COMPOSE_PATH" \
    'privileged: true' \
    "compose permits nested rootless podman during repository tests"
  assert_file_contains "$COMPOSE_PATH" \
    '/var/run/docker.sock:/var/lib/capsule/docker.sock' \
    "compose mounts the host socket where the engine router expects it"
  assert_file_contains "$COMPOSE_PATH" \
    'DOCKER_HOST=unix:///var/lib/capsule/docker.sock' \
    "compose points Docker clients at the routed host socket"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_HOME_HOST_DIR=${CAPSULE_HOME_HOST_DIR:-}' \
    "compose passes host home mount info to nested capsules"
  assert_file_contains "$COMPOSE_PATH" \
    'CAPSULE_HOST_WORKDIR=${CAPSULE_HOST_WORKDIR:-}' \
    "compose passes host workdir to nested capsule"
  assert_file_contains "$COMPOSE_PATH" \
    'environment: GITHUB_API_TOKEN' \
    "compose sources github token from GITHUB_API_TOKEN env"
  assert_file_contains "$COMPOSE_PATH" \
    '- github_api_token' \
    "compose mounts github token as a runtime secret"
  assert_file_contains "$COMPOSE_PATH" \
    '- MISE_SYSTEM_TOOLS' \
    "compose passes MISE_SYSTEM_TOOLS from the build environment"
  assert_file_contains "$README_PATH" \
    'This replaces the entire default list.' \
    "docs say MISE_SYSTEM_TOOLS replaces the defaults"
  assert_file_contains "$README_PATH" \
    'python@3.14 ripgrep ruff ty uv' \
    "custom tool example retains Python tooling"
}

test_dockerfile_tooling_contract() {
  assert_file_contains "$DOCKERFILE_PATH" 'shellcheck' \
    "image installs shellcheck for shell linting"
  assert_file_contains "$DOCKERFILE_PATH" 'tree' \
    "image installs tree for directory visualization"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ARG MISE_VERSION=latest' \
    "image provides a default mise version"
  # shellcheck disable=SC2016
  assert_file_contains "$DOCKERFILE_PATH" \
    'FROM ghcr.io/jdx/mise:${MISE_VERSION} AS mise' \
    "image selects the mise source through a versioned stage"
  assert_file_contains "$DOCKERFILE_PATH" \
    'COPY --from=mise /usr/local/bin/mise /usr/local/bin/mise' \
    "image copies mise from the named source stage"
  assert_file_contains "$DOCKERFILE_PATH" \
    "mise install --system \${MISE_SYSTEM_TOOLS} &&" \
    "image installs system tools with mise"
  assert_file_contains "$DOCKERFILE_PATH" \
    "mise use --path /etc/mise/config.toml --pin \${MISE_SYSTEM_TOOLS}" \
    "image pins system tools in the global mise config"
  assert_file_contains "$DOCKERFILE_PATH" \
    '/usr/local/share/mise/shims:' \
    "image adds shims path to system PATH for config-independent access"
  assert_file_not_contains "$DOCKERFILE_PATH" \
    "mise use --global \${MISE_SYSTEM_TOOLS}" \
    "image no longer activates system tools in the user home"
  assert_file_contains "$DOCKERFILE_PATH" \
    '[wrappers.codex]' \
    "image defines a mise wrapper for Codex"
  # shellcheck disable=SC2016
  assert_file_contains "$DOCKERFILE_PATH" \
    '"$(mise which codex)"' \
    "Codex wrapper resolves the installed binary through mise"
  assert_file_contains "$DOCKERFILE_PATH" \
    'args = ["--dangerously-bypass-approvals-and-sandbox"]' \
    "Codex wrapper disables approvals and sandboxing"
  assert_file_not_contains "$DOCKERFILE_PATH" \
    'RUN cat <<EOF' \
    "Codex wrapper avoids Buildah-incompatible Dockerfile heredocs"
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

# shellcheck disable=SC2016
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
    'SUBORDINATE_ID_COUNT=65536' \
    "entrypoint grants nested podman a complete subordinate ID range"
  # shellcheck disable=SC2016
  assert_file_contains "$ENTRYPOINT_PATH" \
    '"$SUBORDINATE_UID_START" "$SUBORDINATE_ID_COUNT" >/etc/subuid' \
    "entrypoint installs the runtime subordinate UID range"
  # shellcheck disable=SC2016
  assert_file_contains "$ENTRYPOINT_PATH" \
    '"$SUBORDINATE_GID_START" "$SUBORDINATE_ID_COUNT" >/etc/subgid' \
    "entrypoint installs the runtime subordinate GID range"
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
  assert_file_contains "$ENTRYPOINT_PATH" \
    '/run/secrets/github_api_token' \
    "entrypoint reads github token from compose secret mount"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'GH=/usr/local/bin/gh' \
    "entrypoint prefers a direct system gh binary"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'mise --cd / which gh' \
    "entrypoint resolves the system gh install for root and podman users"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'auth login --with-token' \
    "entrypoint refreshes gh credentials from runtime secret"
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

test_build_subcommand_builds_without_running() {
  local tdir="$TEST_TMPDIR/build-command"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_build=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --no-cache

  expected_build="compose -f $COMPOSE_PATH build --no-cache"
  expected_build="$expected_build --build-arg MISE_VERSION=${mise_ver} cli"
  assert_equals "$expected_build" \
    "$(value_from_log ARGS "$log_file")" \
    "build command builds the image"
  assert_file_not_contains "$log_file" ' run --rm ' \
    "build command does not start a Capsule"
}

test_build_subcommand_skips_run_approval() {
  local tdir="$TEST_TMPDIR/build-command-no-approval"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local config_file="$tdir/config/approvals"
  local workdir="$tdir/work"
  mkdir -p "$workdir"
  make_mock_bin "$mock_bin"

  PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$config_file" CAPSULE_RUNTIME=docker \
    CAPSULE_WORKDIR="$workdir" CAPSULE_PRIVATE_HOME=maybe DOCKER_GID=1111 \
    "$SCRIPT_PATH" build --remote builder

  if [[ ! -e "$config_file" ]]; then
    pass "build command does not create a run approval file"
  else
    fail "build command does not create a run approval file"
  fi
  assert_equals "ssh://builder" \
    "$(value_from_log ENV_DOCKER_HOST "$log_file")" \
    "build command accepts a remote host without a workdir"
  pass "build command ignores unrelated run environment options"
}

test_build_subcommand_can_build_only_custom_image() {
  local tdir="$TEST_TMPDIR/build-custom-command"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "build-command:local"

  CAPSULE_CUSTOM_COMPOSE="$custom_compose" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" build --custom

  assert_file_contains "$log_file" \
    "compose -f $COMPOSE_PATH -f $custom_compose build" \
    "build --custom builds the merged custom image"
  assert_file_not_contains "$log_file" ' run --rm ' \
    "build --custom does not start a Capsule"
}

test_build_subcommand_rejects_conflicting_modes() {
  local tdir="$TEST_TMPDIR/build-command-conflict"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --all --custom 2>"$err_file"; then
    fail "build command rejects conflicting modes"
  else
    pass "build command rejects conflicting modes"
  fi
  assert_file_contains "$err_file" \
    '--build-custom cannot be combined with --build' \
    "build command reports conflicting modes"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --runtime 2>"$err_file"; then
    fail "build command rejects a missing runtime"
  else
    pass "build command rejects a missing runtime"
  fi
  assert_file_contains "$err_file" '--runtime requires a value' \
    "build command reports a missing runtime"
}

test_explicit_run_subcommand_starts_capsule() {
  local tdir="$TEST_TMPDIR/run-command"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_run=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" run true

  expected_run="compose -f $COMPOSE_PATH run --rm cli true"
  assert_equals "$expected_run" \
    "$(value_from_log ARGS "$log_file")" \
    "run command starts the Capsule"
}

test_no_cache_flag_applies_to_build_only() {
  local tdir="$TEST_TMPDIR/build-no-cache"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --build --no-cache true

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --no-cache"
  expected_build="$expected_build --build-arg MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "no-cache flag applies to the base build"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "no-cache flag does not change runtime args"
}

# Verify -- passes --build-custom through to the runtime command.
test_build_custom_flag_keeps_runtime_flags() {
  local tdir="$TEST_TMPDIR/build-custom-double-dash"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_args=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    -- --build-custom true

  expected_args="compose -f $COMPOSE_PATH"
  expected_args="$expected_args run --rm cli --build-custom true"

  assert_equals \
    "$expected_args" \
    "$(value_from_log ARGS "$log_file")" \
    "double dash passes build-custom-like flags to runtime command"
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
FROM casual-capsule-cli:latest
EOF
}

test_flag_environment_equivalents() {
  local tdir="$TEST_TMPDIR/flag-environment"
  local mock_bin="$tdir/bin"
  local build_log="$tdir/build-log"
  local custom_log="$tdir/custom-log"
  local home_log="$tdir/home-log"
  local remote_log="$tdir/remote-log"
  local err_file="$tdir/err"
  local home_dir="$tdir/home"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  mkdir -p "$home_dir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "env-capsule:local"

  CAPSULE_BUILD=1 CAPSULE_NO_CACHE=1 DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$build_log" true
  assert_file_contains "$build_log" 'build --no-cache' \
    "CAPSULE_BUILD and CAPSULE_NO_CACHE enable their flags"
  assert_file_contains "$build_log" 'run --rm cli true' \
    "CAPSULE_BUILD still runs the Capsule"

  CAPSULE_BUILD_CUSTOM=1 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$custom_log" true
  assert_file_contains "$custom_log" "-f $custom_compose build" \
    "CAPSULE_BUILD_CUSTOM enables --build-custom"

  HOME="$home_dir" CAPSULE_PRIVATE_HOME=1 DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$home_log" true
  assert_equals "$home_dir/.capsule-home:/home/user" \
    "$(value_from_log ENV_CAPSULE_HOME_MOUNT "$home_log")" \
    "CAPSULE_PRIVATE_HOME enables --private-home"

  CAPSULE_REMOTE=builder:/srv/work \
    CAPSULE_EXTRA_APPROVALS=ssh://builder/srv/work \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$remote_log" true
  assert_equals "ssh://builder" \
    "$(value_from_log ENV_DOCKER_HOST "$remote_log")" \
    "CAPSULE_REMOTE enables --remote"

  if CAPSULE_PRIVATE_HOME=maybe DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$tdir/invalid-log" true 2>"$err_file"; then
    fail "boolean environment options reject invalid values"
  else
    pass "boolean environment options reject invalid values"
  fi
  assert_file_contains "$err_file" \
    'CAPSULE_PRIVATE_HOME must be one of' \
    "invalid boolean environment values report the accepted forms"
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

test_publish_and_volume_flags_forward_to_runtime() {
  local tdir="$TEST_TMPDIR/runtime-options"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_args=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --publish 8080:80 --publish 8443:443 \
    --volume /host/data:/data --volume /host/config:/etc/config:ro true

  expected_args="compose -f $COMPOSE_PATH"
  expected_args="$expected_args run --rm"
  expected_args="$expected_args --publish 8080:80"
  expected_args="$expected_args --publish 8443:443"
  expected_args="$expected_args --volume /host/data:/data"
  expected_args="$expected_args --volume /host/config:/etc/config:ro"
  expected_args="$expected_args cli true"

  assert_equals \
    "$expected_args" \
    "$(value_from_log ARGS "$log_file")" \
    "publish and volume flags, including read-only mounts, reach compose run"
}

test_publish_and_volume_env_forward_to_runtime() {
  local tdir="$TEST_TMPDIR/runtime-options-env"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local publish_specs=""
  local volume_specs=""
  local expected_args=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  publish_specs="8080:80;;8443:443;"
  volume_specs="/host/data:/data;;/host/cache:/cache;"

  CAPSULE_PUBLISH="$publish_specs" CAPSULE_VOLUME="$volume_specs" \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true

  expected_args="compose -f $COMPOSE_PATH"
  expected_args="$expected_args run --rm"
  expected_args="$expected_args --publish 8080:80"
  expected_args="$expected_args --publish 8443:443"
  expected_args="$expected_args --volume /host/data:/data"
  expected_args="$expected_args --volume /host/cache:/cache"
  expected_args="$expected_args cli true"

  assert_equals \
    "$expected_args" \
    "$(value_from_log ARGS "$log_file")" \
    "publish and volume env vars forward to compose run"
}

# shellcheck disable=SC2016
test_empty_optional_arrays_use_nounset_safe_expansion() {
  assert_file_contains "$CORE_PATH" \
    '${RUNTIME_OPTS[@]+${RUNTIME_OPTS[@]}}' \
    "runtime options expansion is safe under bash 4.3 nounset"
  assert_file_contains "$CORE_PATH" \
    '${RUNTIME_ARGS[@]+${RUNTIME_ARGS[@]}}' \
    "runtime args expansion is safe under bash 4.3 nounset"
  assert_file_contains "$CORE_PATH" \
    '${ssh_args[@]+${ssh_args[@]}}' \
    "remote ssh args expansion is safe under bash 4.3 nounset"
  assert_file_contains "$CORE_PATH" \
    '${build_no_cache_args[@]+"${build_no_cache_args[@]}"}' \
    "build no-cache args expansion is safe under bash 4.3 nounset"
}

test_check_all_docker_linters_use_capsule_host_workdir() {
  local tdir="$TEST_TMPDIR/check-all-host-workdir"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local out_file="$tdir/out"
  mkdir -p "$mock_bin"
  ln -s "$(command -v bash)" "$mock_bin/bash"
  ln -s "$(command -v dirname)" "$mock_bin/dirname"

  cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *koalaman/shellcheck* ]]; then
  file_count=0
  for arg in "$@"; do
    case "$arg" in
      /mnt/*) file_count=$((file_count + 1)) ;;
    esac
  done
  [[ "$file_count" -eq 1 ]] || exit 1
fi
printf 'DOCKER_ARGS=%s\n' "$*" >>"${MOCK_LOG:?MOCK_LOG is required}"
EOF
  chmod +x "$mock_bin/docker"

  if ! PATH="$mock_bin" MOCK_LOG="$log_file" \
    CAPSULE_WORKDIR="$ROOT_DIR" \
    CAPSULE_HOST_WORKDIR=/host/workspace \
    "$CHECK_ALL_PATH" >"$out_file" 2>&1; then
    fail "check_all accepts the host-visible workdir"
    cat "$out_file" >&2
    return
  fi

  assert_file_contains "$log_file" \
    "-v /host/workspace:/mnt" \
    "check_all docker linters mount host-visible capsule workdir"
  assert_file_not_contains "$log_file" \
    "-v $ROOT_DIR:/mnt" \
    "check_all docker linters avoid container-only workdir mounts"
  pass "check_all shellchecks each file independently like CI"
}

# A mise shim with no version pinned sits on PATH and fails the moment it
# runs. Treat such a linter as absent rather than as a failing check.
test_check_all_ignores_an_unusable_linter() {
  local tdir="$TEST_TMPDIR/check-all-unusable-linter"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$mock_bin"
  ln -s "$(command -v bash)" "$mock_bin/bash"
  ln -s "$(command -v dirname)" "$mock_bin/dirname"

  cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'DOCKER_ARGS=%s\n' "$*" >>"${MOCK_LOG:?MOCK_LOG is required}"
EOF
  cat >"$mock_bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'mise ERROR No version is set for shim: shellcheck\n' >&2
exit 1
EOF
  chmod +x "$mock_bin/docker" "$mock_bin/shellcheck"

  if PATH="$mock_bin" MOCK_LOG="$log_file" \
    CAPSULE_WORKDIR="$ROOT_DIR" \
    CAPSULE_HOST_WORKDIR=/host/workspace \
    "$CHECK_ALL_PATH" >"$tdir/out" 2>&1; then
    pass "an unusable linter does not fail the checks"
  else
    fail "an unusable linter does not fail the checks"
  fi

  assert_file_contains "$log_file" \
    'koalaman/shellcheck' \
    "an unusable shellcheck falls through to the container image"
}

test_check_all_reports_skip_reasons() {
  local tdir="$TEST_TMPDIR/check-all-skip-reasons"
  local mock_bin="$tdir/bin"
  local out_file="$tdir/out"
  mkdir -p "$mock_bin"
  ln -s "$(command -v bash)" "$mock_bin/bash"
  ln -s "$(command -v dirname)" "$mock_bin/dirname"

  if PATH="$mock_bin" "$CHECK_ALL_PATH" >"$out_file" 2>&1; then
    pass "check_all accepts unavailable optional linters"
  else
    fail "check_all accepts unavailable optional linters"
  fi
  assert_file_contains "$out_file" 'Skipped:' \
    "check_all prints a skip-reason section"
  assert_file_contains "$out_file" \
    'dclint unavailable; skipping Compose lint' \
    "check_all names a missing Compose linter"
  assert_file_contains "$out_file" \
    'shellcheck unavailable; skipping shell lint' \
    "check_all names a missing shell linter"
}

# Give the doctor a host of its own: a podman that answers rootless, a
# systemd that grants scopes, and a shellcheck that fails the way a mise
# shim with no version does.
make_doctor_bin() {
  local dir="$1"
  local tool=""

  mkdir -p "$dir"
  for tool in bash id uname grep; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done

  cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$dir/podman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *OCIRuntime.Name*) printf 'runc\n' ;;
  *Rootless*) printf 'true 2\n' ;;
esac
exit 0
EOF

  cat >"$dir/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$dir/busctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat >"$dir/shellcheck" <<'EOF'
#!/usr/bin/env bash
printf 'mise ERROR No version is set for shim: shellcheck\n' >&2
exit 1
EOF

  chmod +x "$dir/docker" "$dir/podman" "$dir/systemd-run" \
    "$dir/busctl" "$dir/shellcheck"
}

test_doctor_reports_each_backend_and_probes_by_running() {
  local tdir="$TEST_TMPDIR/doctor"
  local bin_dir="$tdir/bin"
  local out_file="$tdir/out"
  mkdir -p "$tdir"
  make_doctor_bin "$bin_dir"

  if ! bash -n "$DOCTOR_PATH"; then
    fail "capsule doctor has valid shell syntax"
  else
    pass "capsule doctor has valid shell syntax"
  fi

  # The verdict depends on the host; the report does not.
  PATH="$bin_dir" "$DOCTOR_PATH" >"$out_file" 2>&1 || true

  assert_file_contains "$out_file" \
    'Docker backend' \
    "the doctor reports on the Docker backend"
  assert_file_contains "$out_file" \
    'podman backend' \
    "the doctor reports on the podman backend"
  assert_file_contains "$out_file" \
    'Repository tooling' \
    "the doctor reports on the repository's own linters"
  assert_file_contains "$out_file" \
    'systemd answers on the session bus' \
    "the doctor probes the bus the container runtime resolves"
  assert_file_contains "$out_file" \
    'podman uses the runc runtime, not crun' \
    "the doctor names a runtime that fails where crun does not"
  assert_file_contains "$out_file" \
    'shellcheck is on PATH but does not run' \
    "the doctor tells an unrunnable shim from a missing tool"
  assert_file_contains "$out_file" \
    'passed,' \
    "the doctor ends with a tally"
  assert_file_not_contains "$out_file" $'\033[' \
    "the doctor leaves redirected output uncolored"
  assert_file_contains "$DOCTOR_PATH" "-z \"\${NO_COLOR:-}\"" \
    "the doctor honors NO_COLOR before coloring output"
}

# The remedy has to fit the cause: a session bus that systemd is not on is a
# different repair from having no user bus at all.
test_doctor_names_a_stale_session_bus() {
  local tdir="$TEST_TMPDIR/doctor-bus"
  local bin_dir="$tdir/bin"
  local out_file="$tdir/out"
  local run_dir="$tdir/run"
  mkdir -p "$tdir" "$run_dir"
  make_doctor_bin "$bin_dir"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$bin_dir/busctl"
  chmod +x "$bin_dir/busctl"
  : >"$run_dir/bus"

  PATH="$bin_dir" XDG_RUNTIME_DIR="$run_dir" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/dbus-Legacy" \
    "$DOCTOR_PATH" >"$out_file" 2>&1 || true

  assert_file_contains "$out_file" \
    'systemd does not answer on the session bus' \
    "the doctor fails a host whose session bus has no systemd on it"
  assert_file_contains "$out_file" \
    'DBUS_SESSION_BUS_ADDRESS skips' \
    "the doctor blames the session bus address when that is the cause"

  rm -f "$run_dir/bus"
  PATH="$bin_dir" XDG_RUNTIME_DIR="$run_dir" \
    DBUS_SESSION_BUS_ADDRESS="" \
    "$DOCTOR_PATH" >"$out_file" 2>&1 || true

  assert_file_contains "$out_file" \
    'install dbus-user-session' \
    "the doctor names the package when no user bus exists at all"
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

# Verify --build-custom fails early without CAPSULE_CUSTOM_COMPOSE.
test_build_custom_flag_requires_custom_compose() {
  local tdir="$TEST_TMPDIR/build-custom-missing-config"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --build-custom true 2>"$err_file"; then
    fail "build-custom flag requires a custom compose"
  else
    pass "build-custom flag requires a custom compose"
  fi
  assert_file_contains "$err_file" \
    "--build-custom requires CAPSULE_CUSTOM_COMPOSE" \
    "build-custom flag reports a clear missing compose error"
}

# Verify --build and --build-custom cannot be combined.
test_build_and_build_custom_flags_conflict() {
  local tdir="$TEST_TMPDIR/build-flag-conflict"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --build --build-custom true 2>"$err_file"; then
    fail "build flags conflict cleanly"
  else
    pass "build flags conflict cleanly"
  fi
  assert_file_contains "$err_file" \
    "--build-custom cannot be combined with --build" \
    "build flag conflict reports a clear error"
}

test_private_home_flag_uses_user_home_bind_mount() {
  local tdir="$TEST_TMPDIR/private-home"
  local home_dir="$tdir/home"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$home_dir"
  make_mock_bin "$mock_bin"

  HOME="$home_dir" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" --private-home true

  assert_equals "$home_dir/.capsule-home" \
    "$(value_from_log ENV_CAPSULE_HOME_HOST_DIR "$log_file")" \
    "private-home flag exports the host home bind path"
  assert_equals "$home_dir/.capsule-home:/home/user" \
    "$(value_from_log ENV_CAPSULE_HOME_MOUNT "$log_file")" \
    "private-home flag overrides the home mount"
  if [[ -d "$home_dir/.capsule-home" ]]; then
    pass "private-home flag creates the local home bind directory"
  else
    fail "private-home flag creates the local home bind directory"
  fi
}

test_private_home_uses_host_path_map_for_home_dir() {
  local tdir="$TEST_TMPDIR/private-home-path-map"
  local home_dir="$tdir/container-home"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local cfg_file="$tdir/config"
  local host_path_map=""
  mkdir -p "$home_dir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "/host/workspace/project" >"$cfg_file"
  host_path_map="/workspace=/host/workspace"
  host_path_map="${host_path_map}:${home_dir}=/host/home/alice"

  if HOME="$home_dir" DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/workspace/project" \
    CAPSULE_HOST_PATH_MAP="$host_path_map" \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" --private-home true </dev/null; then
    pass "private-home uses host path map for home dir"
  else
    fail "private-home uses host path map for home dir"
  fi

  assert_equals "/host/home/alice/.capsule-home" \
    "$(value_from_log ENV_CAPSULE_HOME_HOST_DIR "$log_file")" \
    "private-home resolves mapped host home path"
  assert_equals "/host/home/alice/.capsule-home:/home/user" \
    "$(value_from_log ENV_CAPSULE_HOME_MOUNT "$log_file")" \
    "private-home mount uses mapped host home path"
  if [[ -e "$home_dir/.capsule-home" ]]; then
    fail "private-home does not create a container-local home dir"
  else
    pass "private-home does not create a container-local home dir"
  fi
}

test_private_home_requires_home_mapping_with_host_path_map() {
  local tdir="$TEST_TMPDIR/private-home-path-map-missing"
  local home_dir="$tdir/container-home"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local cfg_file="$tdir/config"
  mkdir -p "$home_dir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "/host/workspace/project" >"$cfg_file"

  if HOME="$home_dir" DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/workspace/project" \
    CAPSULE_HOST_PATH_MAP="/workspace=/host/workspace" \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" --private-home true </dev/null 2>"$err_file"; then
    fail "private-home requires a home mapping with host path map"
  else
    pass "private-home requires a home mapping with host path map"
  fi

  assert_file_contains "$err_file" \
    "CAPSULE_HOST_PATH_MAP requires a mapping for" \
    "private-home reports a clear missing home mapping error"
}

test_remote_flag_requires_target() {
  local tdir="$TEST_TMPDIR/remote-missing-target"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --remote --build true 2>"$err_file"; then
    fail "remote flag requires a target"
  else
    pass "remote flag requires a target"
  fi

  assert_file_contains "$err_file" \
    "--remote requires HOST[:PORT]:/absolute/workdir" \
    "remote flag reports a clear missing target error"
}

test_remote_flag_requires_absolute_workdir_syntax() {
  local tdir="$TEST_TMPDIR/remote-relative-workdir"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --remote builder:workspace true 2>"$err_file"; then
    fail "remote flag requires an absolute workdir"
  else
    pass "remote flag requires an absolute workdir"
  fi

  assert_file_contains "$err_file" \
    "--remote requires HOST[:PORT]:/absolute/workdir" \
    "remote flag reports a clear syntax error for non-absolute targets"
}

test_list_finds_docker_and_podman_capsules() {
  local tdir="$TEST_TMPDIR/list-local"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local out_file="$tdir/out"
  local header_name_column=""
  local row_name_column=""
  local docker_inspect=$'CAPSULE_HOST_WORKDIR=/srv/docker\n'
  local docker_ps=$'docker-id\tdocker-capsule\t2 hours\timage:d\t'
  local podman_ps=$'podman-id\tpodman-capsule\t5 minutes\timage:p\t'
  docker_inspect+='CAPSULE_UID=1000'
  docker_ps+=$'Up 2 hours\t'
  podman_ps+=$'Up 5 minutes\t8080/tcp'
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  CAPSULE_RUNTIME=auto \
    MOCK_DOCKER_PS="$docker_ps" \
    MOCK_DOCKER_INSPECT="$docker_inspect" \
    MOCK_PODMAN_PS="$podman_ps" \
    MOCK_PODMAN_INSPECT=$'CAPSULE_HOST_WORKDIR=/srv/podman\nCAPSULE_UID=1000' \
    MOCK_ID_USER=bob \
    run_capsule "$mock_bin" "$log_file" list >"$out_file"

  assert_file_contains "$out_file" 'HOST_DIR' \
    "list prints a stable header"
  assert_file_contains "$out_file" 'bob' \
    "list resolves the creator from CAPSULE_UID"
  assert_file_contains "$out_file" '/srv/docker' \
    "list reports the Docker host workdir"
  assert_file_contains "$out_file" '/srv/podman' \
    "list reports the podman host workdir"
  header_name_column="$(awk 'NR == 1 { print index($0, "NAME") }' \
    "$out_file")"
  row_name_column="$(awk 'NR == 2 { print index($0, "docker-capsule") }' \
    "$out_file")"
  assert_equals "$header_name_column" "$row_name_column" \
    "list aligns table columns"
  assert_file_not_contains "$log_file" 'ARGS=compose' \
    "list does not start a Capsule"
}

test_list_queries_remote_docker_without_workdir_or_approval() {
  local tdir="$TEST_TMPDIR/list-remote"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local out_file="$tdir/out"
  local env_out_file="$tdir/env-out"
  local docker_inspect=$'CAPSULE_HOST_WORKDIR=/remote/project\n'
  docker_inspect+='CAPSULE_UID=2000'
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  CAPSULE_RUNTIME=auto \
    MOCK_DOCKER_PS=$'remote-id\tremote-capsule\t3 days\timage:r\tUp 3 days\t' \
    MOCK_DOCKER_INSPECT="$docker_inspect" \
    MOCK_SSH_OUTPUT=remote-user \
    run_capsule "$mock_bin" "$log_file" \
    list --remote builder:2222 >"$out_file"

  assert_file_contains "$out_file" 'remote-user' \
    "remote list resolves a Capsule creator through SSH"
  assert_file_contains "$out_file" '/remote/project' \
    "remote list reports the remote host workdir"
  assert_file_contains "$log_file" \
    'DOCKER_PS_HOST=ssh://builder:2222' \
    "remote list queries Docker through its SSH endpoint"
  assert_file_not_contains "$log_file" 'PODMAN_PS_ARGS=' \
    "remote list does not query local podman"

  CAPSULE_RUNTIME=auto CAPSULE_REMOTE=builder:2222 \
    MOCK_DOCKER_PS=$'remote-id\tremote-capsule\t3 days\timage:r\tUp 3 days\t' \
    MOCK_DOCKER_INSPECT="$docker_inspect" \
    MOCK_SSH_OUTPUT=remote-user \
    run_capsule "$mock_bin" "$log_file" list >"$env_out_file"
  assert_file_contains "$env_out_file" 'remote-user' \
    "CAPSULE_REMOTE selects the remote list target"
}

test_list_rejects_launch_commands() {
  local tdir="$TEST_TMPDIR/list-command"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if run_capsule "$mock_bin" "$log_file" list true 2>"$err_file"; then
    fail "list rejects launch commands"
  else
    pass "list rejects launch commands"
  fi
  assert_file_contains "$err_file" \
    'unknown list option: true' \
    "list reports its launch-command conflict"
}

test_remote_flag_requires_authorization() {
  local tdir="$TEST_TMPDIR/remote-approval"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local cfg_file="$tdir/config"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "${CAPSULE_WORKDIR:-$(pwd -P)}" >"$cfg_file"

  if DOCKER_GID=1111 CAPSULE_RUNTIME=docker \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" "$SCRIPT_PATH" \
    --remote builder:/srv/work true </dev/null 2>"$err_file"; then
    fail "remote target requires allowlist approval"
  else
    pass "remote target requires allowlist approval"
  fi

  assert_file_contains "$err_file" \
    "ssh://builder/srv/work not in allowlist" \
    "remote target reports a clear allowlist error"
}

test_run_confirmation_supports_only_once() {
  local tdir="$TEST_TMPDIR/run-confirmation"
  local mock_bin="$tdir/bin"
  local yes_log="$tdir/yes-log"
  local yes_cfg="$tdir/yes-config"
  local once_log="$tdir/once-log"
  local once_cfg="$tdir/once-config"
  local no_log="$tdir/no-log"
  local no_cfg="$tdir/no-config"
  local pty_log="$tdir/pty-log"
  local script_status=0
  local run_cmd=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if ! command -v script >/dev/null 2>&1; then
    skip "script not installed; skipping run confirmation TTY test"
    return
  fi
  if ! script -q -e -c true /dev/null >/dev/null 2>&1; then
    skip "script lacks -e support; skipping run confirmation TTY test"
    return
  fi
  script -q -e -c 'exit 7' /dev/null >/dev/null 2>&1 || script_status=$?
  if [[ "$script_status" -ne 7 ]]; then
    skip "script does not preserve exits; skipping run confirmation TTY test"
    return
  fi

  run_cmd="$(printf 'PATH=%q MOCK_LOG=%q CAPSULE_CONFIG=%q ' \
    "$mock_bin:$PATH" "$yes_log" "$yes_cfg")"
  run_cmd="${run_cmd}$(printf \
    'DOCKER_GID=1111 CAPSULE_RUNTIME=docker %q true' "$SCRIPT_PATH")"
  if printf 'y' | script -q -e -c "$run_cmd" /dev/null \
    >"$pty_log" 2>&1; then
    pass "run confirmation accepts yes"
  else
    fail "run confirmation accepts yes"
  fi
  assert_file_contains "$yes_cfg" "$ROOT_DIR" \
    "run confirmation yes saves approval"
  assert_file_contains "$yes_log" "run --rm cli true" \
    "run confirmation yes allows run"

  run_cmd="$(printf 'PATH=%q MOCK_LOG=%q CAPSULE_CONFIG=%q ' \
    "$mock_bin:$PATH" "$once_log" "$once_cfg")"
  run_cmd="${run_cmd}$(printf \
    'DOCKER_GID=1111 CAPSULE_RUNTIME=docker %q true' "$SCRIPT_PATH")"
  if printf 'o' | script -q -e -c "$run_cmd" /dev/null \
    >"$pty_log" 2>&1; then
    pass "run confirmation accepts only once"
  else
    fail "run confirmation accepts only once"
  fi
  if [[ -e "$once_cfg" ]]; then
    assert_file_not_contains "$once_cfg" "$ROOT_DIR" \
      "run confirmation only once skips approval file"
  else
    pass "run confirmation only once skips approval file"
  fi
  assert_file_contains "$once_log" "run --rm cli true" \
    "run confirmation only once allows run"

  run_cmd="$(printf 'PATH=%q MOCK_LOG=%q CAPSULE_CONFIG=%q ' \
    "$mock_bin:$PATH" "$no_log" "$no_cfg")"
  run_cmd="${run_cmd}$(printf \
    'DOCKER_GID=1111 CAPSULE_RUNTIME=docker %q true' "$SCRIPT_PATH")"
  if printf '\n' | script -q -e -c "$run_cmd" /dev/null \
    >"$pty_log" 2>&1; then
    fail "run confirmation default rejects run"
  else
    pass "run confirmation default rejects run"
  fi
}

test_remote_flag_skips_local_workdir_approval() {
  local tdir="$TEST_TMPDIR/remote-no-local-approval"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local cfg_file="$tdir/config"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "ssh://builder/srv/work" >"$cfg_file"

  if DOCKER_GID=1111 CAPSULE_RUNTIME=docker \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" "$SCRIPT_PATH" \
    --remote builder:/srv/work true </dev/null; then
    pass "remote flag skips local workdir approval"
  else
    fail "remote flag skips local workdir approval"
  fi

  assert_equals "ssh://builder" \
    "$(value_from_log ENV_DOCKER_HOST "$log_file")" \
    "remote mode still exports DOCKER_HOST without local approval"
}

test_remote_flag_builds_and_runs_over_ssh() {
  local tdir="$TEST_TMPDIR/remote-build"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local expected_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=2222 CAPSULE_EXTRA_APPROVALS="ssh://builder/srv/work" \
    run_capsule "$mock_bin" "$log_file" \
    -r builder:/srv/work --build true

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --build-arg MISE_VERSION=${mise_ver}"
  expected_build="$expected_build cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH"
  expected_run="$expected_run run --rm cli true"

  assert_equals "ssh://builder" \
    "$(value_from_log ENV_DOCKER_HOST "$log_file")" \
    "remote flag exports DOCKER_HOST over ssh"
  assert_equals "/srv/work" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "remote flag exports remote CAPSULE_HOST_WORKDIR"
  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "remote build still runs compose build first"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "remote build still runs compose runtime"
}

test_remote_flag_accepts_host_port_syntax() {
  local tdir="$TEST_TMPDIR/remote-port"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID="" CAPSULE_EXTRA_APPROVALS="ssh://builder:2222/srv/work" \
    MOCK_SSH_OUTPUT=7654 run_capsule "$mock_bin" "$log_file" \
    --remote builder:2222:/srv/work true

  assert_equals "ssh://builder:2222" \
    "$(value_from_log ENV_DOCKER_HOST "$log_file")" \
    "remote flag keeps the port in DOCKER_HOST"
  assert_equals "/srv/work" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "remote port syntax still exports the remote workdir"
  assert_equals "7654" \
    "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "remote port syntax still auto-detects DOCKER_GID"
  assert_file_contains "$log_file" \
    "SSH_ARGS=-p 2222 builder" \
    "remote port syntax passes the ssh port to helper commands"
}

test_remote_flag_autodetects_docker_gid_over_ssh() {
  local tdir="$TEST_TMPDIR/remote-gid"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID="" CAPSULE_EXTRA_APPROVALS="ssh://builder/srv/work" \
    MOCK_SSH_OUTPUT=7654 run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/work true

  assert_equals "7654" \
    "$(value_from_log ENV_DOCKER_GID "$log_file")" \
    "remote flag auto-detects DOCKER_GID over ssh"
  assert_file_contains "$log_file" \
    "SSH_ARGS=builder" \
    "remote gid detection queries the remote host"
  assert_file_contains "$log_file" \
    "/var/run/docker.sock" \
    "remote gid detection inspects the remote Docker socket"
}

test_remote_private_home_uses_remote_user_home() {
  local tdir="$TEST_TMPDIR/remote-private-home"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_GID=2222 CAPSULE_EXTRA_APPROVALS="ssh://builder/srv/work" \
    MOCK_SSH_HOME_DIR="/srv/home/alice/.capsule-home" \
    run_capsule "$mock_bin" "$log_file" \
    -r builder:/srv/work --private-home true

  assert_equals "/srv/home/alice/.capsule-home" \
    "$(value_from_log ENV_CAPSULE_HOME_HOST_DIR "$log_file")" \
    "remote private-home resolves the remote user home path"
  assert_equals "/srv/home/alice/.capsule-home:/home/user" \
    "$(value_from_log ENV_CAPSULE_HOME_MOUNT "$log_file")" \
    "remote private-home overrides the home mount"
  assert_file_contains "$log_file" \
    ".capsule-home" \
    "remote private-home queries the remote home path over ssh"
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

test_custom_compose_no_cache_builds_only_affect_build_steps() {
  local tdir="$TEST_TMPDIR/custom-build-no-cache"
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
    run_capsule "$mock_bin" "$log_file" --build --no-cache true

  expected_build="ARGS=compose -f $COMPOSE_PATH"
  expected_build="$expected_build build --no-cache"
  expected_build="$expected_build --build-arg MISE_VERSION=${mise_ver} cli"
  expected_custom_build="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_custom_build="$expected_custom_build build --no-cache"
  expected_custom_build="$expected_custom_build --build-arg"
  expected_custom_build="$expected_custom_build MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "no-cache flag applies to the base image build"
  assert_equals \
    "$expected_custom_build" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "no-cache flag applies to the merged config build"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 3 "$log_file")" \
    "no-cache flag does not change merged runtime args"
}

# Verify --build-custom skips the base build and runs the merged config.
test_custom_compose_build_custom_then_runs() {
  local tdir="$TEST_TMPDIR/custom-build-only"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local expected_custom_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "python-capsule:local"

  DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" --build-custom true

  expected_custom_build="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_custom_build="$expected_custom_build build --build-arg"
  expected_custom_build="$expected_custom_build MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_custom_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "build-custom flag builds only the merged config"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "build-custom flag still runs the merged config"
}

test_build_custom_flag_without_runtime_args() {
  local tdir="$TEST_TMPDIR/build-custom-no-args"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local expected_custom_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "python-capsule:local"

  DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" --build-custom

  expected_custom_build="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_custom_build="$expected_custom_build build --build-arg"
  expected_custom_build="$expected_custom_build MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli"

  assert_equals \
    "$expected_custom_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "build-custom flag works without runtime args (build call)"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "build-custom flag works without runtime args (run call)"
}

test_build_custom_no_cache_applies_to_custom_build_only() {
  local tdir="$TEST_TMPDIR/build-custom-no-cache"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local custom_dir="$tdir/custom"
  local custom_compose="$custom_dir/compose.yml"
  local expected_custom_build=""
  local expected_run=""
  local mise_ver="2024.1.0"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "python-capsule:local"

  DOCKER_GID=1111 CAPSULE_CUSTOM_COMPOSE="$custom_compose" \
    run_capsule "$mock_bin" "$log_file" --build-custom --no-cache true

  expected_custom_build="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_custom_build="$expected_custom_build build --no-cache"
  expected_custom_build="$expected_custom_build --build-arg"
  expected_custom_build="$expected_custom_build MISE_VERSION=${mise_ver} cli"
  expected_run="ARGS=compose -f $COMPOSE_PATH -f $custom_compose"
  expected_run="$expected_run run --rm cli true"

  assert_equals \
    "$expected_custom_build" \
    "$(entry_from_log ARGS 1 "$log_file")" \
    "no-cache flag applies to build-custom"
  assert_equals \
    "$expected_run" \
    "$(entry_from_log ARGS 2 "$log_file")" \
    "no-cache flag does not affect build-custom runtime args"
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

test_debug_mode_enables_xtrace() {
  local tdir="$TEST_TMPDIR/debug-mode"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  CAPSULE_DEBUG=1 DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" true 2>"$err_file"

  assert_file_contains "$err_file" \
    "+ set -euo pipefail" \
    "CAPSULE_DEBUG=1 enables shell xtrace"
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

test_host_path_map_remaps_container_workdir() {
  local tdir="$TEST_TMPDIR/host-path-map"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local cfg_file="$tdir/config"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "/host/workspace/project/subdir" >"$cfg_file"

  if DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/workspace/project/subdir" \
    CAPSULE_HOST_PATH_MAP="/workspace=/host/workspace:/src=/host/src" \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" true </dev/null; then
    pass "host path map remaps container workdir"
  else
    fail "host path map remaps container workdir"
  fi

  assert_equals "/host/workspace/project/subdir" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "host path map remaps container workdir to daemon-host path"
}

test_host_path_map_uses_first_match() {
  local tdir="$TEST_TMPDIR/host-path-map-first-match"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local cfg_file="$tdir/config"
  local host_path_map=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "/host/first/project" >"$cfg_file"
  host_path_map="/workspace=/host/first"
  host_path_map="${host_path_map}:/workspace/project=/host/second"

  if DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/workspace/project" \
    CAPSULE_HOST_PATH_MAP="$host_path_map" \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" true </dev/null; then
    pass "host path map uses first match"
  else
    fail "host path map uses first match"
  fi

  assert_equals "/host/first/project" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "host path map uses the first matching prefix"
}

test_host_path_map_uses_mapped_allowlist_entry() {
  local tdir="$TEST_TMPDIR/host-path-map-approval"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local cfg_file="$tdir/config"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "/host/workspace/project" >"$cfg_file"

  if DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/workspace/project" \
    CAPSULE_HOST_PATH_MAP="/workspace=/host/workspace" \
    PATH="$mock_bin:$PATH" \
    MOCK_LOG="$log_file" \
    CAPSULE_CONFIG="$cfg_file" \
    CAPSULE_HOST_WORKDIR="${CAPSULE_HOST_WORKDIR-}" \
    CAPSULE_HOME_HOST_DIR="${CAPSULE_HOME_HOST_DIR-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" true </dev/null; then
    pass "host path map uses mapped allowlist entry"
  else
    fail "host path map uses mapped allowlist entry"
  fi

  assert_equals "/host/workspace/project" \
    "$(value_from_log ENV_CAPSULE_HOST_WORKDIR "$log_file")" \
    "host path map keeps using the mapped daemon-host path"
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

test_nested_private_home_uses_host_visible_home_dir() {
  local tdir="$TEST_TMPDIR/nested-private-home"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  make_mock_bin "$mock_bin"

  DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/home/workspace/project" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    CAPSULE_HOME_HOST_DIR="/host/home/alice/.capsule-home" \
    run_capsule "$mock_bin" "$log_file" --private-home true

  assert_equals "/host/home/alice/.capsule-home" \
    "$(value_from_log ENV_CAPSULE_HOME_HOST_DIR "$log_file")" \
    "nested private-home reuses the host-visible home path"
  assert_equals "/host/home/alice/.capsule-home:/home/user" \
    "$(value_from_log ENV_CAPSULE_HOME_MOUNT "$log_file")" \
    "nested private-home keeps the host-visible home mount"
}

test_nested_private_home_requires_host_visible_home_dir() {
  local tdir="$TEST_TMPDIR/nested-private-home-missing"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/home/workspace/project" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    HOME="/home/user" \
    run_capsule "$mock_bin" "$log_file" --private-home true \
    2>"$err_file"; then
    fail "nested private-home requires a host-visible home path"
  else
    pass "nested private-home requires a host-visible home path"
  fi

  assert_file_contains "$err_file" \
    "--private-home inside Capsule requires CAPSULE_HOME_HOST_DIR" \
    "nested private-home reports a clear host-path error"
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
#-------------------------------------------------------------------------------
# podman backend
#
# The launcher's podman path is asserted through a mocked `podman`, and the
# in-Capsule engine router against mocked engines, because the real thing
# needs a rootless-capable host that CI cannot be assumed to be. What neither
# can cover -- a real engine serving a real project -- is the operator check
# in tmp/verify-podman-backend.sh.
#-------------------------------------------------------------------------------

# Prepare a case directory with its own mock PATH, and set the paths the
# assertions read. Keeps each case to what it is actually testing.
setup_mock_case() {
  CASE_DIR="$TEST_TMPDIR/$1"
  CASE_BIN="$CASE_DIR/bin"
  CASE_LOG="$CASE_DIR/log"
  CASE_ERR="$CASE_DIR/err"

  mkdir -p "$CASE_DIR"
  make_mock_bin "$CASE_BIN"
}

# Assert that one of the podman invocations carried the given fragment.
assert_podman_args_contain() {
  local log_file="$1"
  local needle="$2"
  local msg="$3"

  if grep -F 'PODMAN_ARGS=' "$log_file" | grep -Fq -- "$needle"; then
    pass "$msg"
  else
    fail "$msg (missing: $needle)"
  fi
}

# Assert that no podman invocation carried the given fragment.
assert_podman_args_lack() {
  local log_file="$1"
  local needle="$2"
  local msg="$3"

  if grep -F 'PODMAN_ARGS=' "$log_file" | grep -Fq -- "$needle"; then
    fail "$msg (unexpected: $needle)"
  else
    pass "$msg"
  fi
}

test_podman_backend_runs_container_with_keep_id() {
  setup_mock_case podman-run

  CAPSULE_UID=1000 CAPSULE_GID=100 CAPSULE_RUNTIME=podman \
    run_capsule "$CASE_BIN" "$CASE_LOG" claude

  assert_podman_args_contain "$CASE_LOG" \
    '--userns keep-id:uid=1000,gid=100' \
    "podman backend maps the host user onto the image's account"
  assert_podman_args_contain "$CASE_LOG" \
    '--user user' \
    "podman backend starts directly as the unprivileged image account"
  assert_podman_args_contain "$CASE_LOG" \
    ':/home/workspace' \
    "podman backend mounts the workspace"
  assert_podman_args_contain "$CASE_LOG" \
    '--volume casual-capsule-home:/home/user' \
    "podman backend mounts the persistent home volume"
  assert_podman_args_contain "$CASE_LOG" \
    '--privileged --security-opt label=disable --device /dev/fuse' \
    "podman backend grants what a nested engine needs"
  assert_podman_args_contain "$CASE_LOG" \
    '--env CAPSULE_RUNTIME=podman' \
    "podman backend tells the entrypoint which backend it is under"
  assert_podman_args_contain "$CASE_LOG" \
    '--env CAPSULE_UID=1000' \
    "podman backend records the host UID for Capsule queries"
  assert_podman_args_contain "$CASE_LOG" \
    'casual-capsule:local claude' \
    "podman backend passes the command after the image"
}

# Verify local podman sees a nested Capsule path, not its outer Docker path.
test_nested_capsule_podman_uses_local_workdir() {
  local nested_dir="/home/workspace/project/subdir"
  setup_mock_case podman-nested-workdir

  CAPSULE_RUNTIME=podman \
    CAPSULE_WORKDIR="$nested_dir" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true

  assert_podman_args_contain "$CASE_LOG" \
    "--volume ${nested_dir}:/home/workspace" \
    "nested podman mounts the workspace path visible inside its Capsule"
  assert_podman_args_lack "$CASE_LOG" \
    '/host/workspace/project/subdir:/home/workspace' \
    "nested podman does not mount the outer Docker daemon path"
}

test_podman_inner_volume_is_per_workspace() {
  local first_volume=""
  local second_volume=""
  setup_mock_case podman-inner
  mkdir -p "$CASE_DIR/project-one" "$CASE_DIR/project-two"

  CAPSULE_RUNTIME=podman CAPSULE_WORKDIR="$CASE_DIR/project-one" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true
  CAPSULE_RUNTIME=podman CAPSULE_WORKDIR="$CASE_DIR/project-two" \
    run_capsule "$CASE_BIN" "$CASE_DIR/second" true

  first_volume="$(grep -o 'capsule-inner-[^ ]*' "$CASE_LOG" | head -n1)"
  second_volume="$(grep -o 'capsule-inner-[^ ]*' "$CASE_DIR/second" | head -n1)"

  assert_podman_args_contain "$CASE_LOG" \
    ':/var/lib/capsule/inner' \
    "podman backend mounts an inner engine volume"

  if [[ -n "$first_volume" ]] && [[ "$first_volume" != "$second_volume" ]]; then
    pass "each workspace gets its own inner engine storage"
  else
    fail "each workspace gets its own inner engine storage"
  fi

  CAPSULE_RUNTIME=podman CAPSULE_WORKDIR="$CASE_DIR/project-one" \
    run_capsule "$CASE_BIN" "$CASE_DIR/again" true
  if grep -Fq "$first_volume" "$CASE_DIR/again"; then
    pass "the same workspace reuses its inner engine storage"
  else
    fail "the same workspace reuses its inner engine storage"
  fi
}

test_podman_backend_translates_publish_and_volume() {
  setup_mock_case podman-options

  CAPSULE_RUNTIME=podman run_capsule "$CASE_BIN" "$CASE_LOG" \
    --publish 8080:80 --volume /host/data:/data true

  assert_podman_args_contain "$CASE_LOG" \
    '--publish 8080:80' \
    "podman backend forwards published ports"
  assert_podman_args_contain "$CASE_LOG" \
    '--volume /host/data:/data' \
    "podman backend forwards runtime volumes"
}

test_podman_backend_mounts_the_token_secret() {
  setup_mock_case podman-secret

  CAPSULE_RUNTIME=podman GITHUB_API_TOKEN=token-value \
    run_capsule "$CASE_BIN" "$CASE_LOG" true

  assert_podman_args_contain "$CASE_LOG" \
    ':/run/secrets/github_api_token:ro' \
    "podman backend mounts the token where the entrypoint reads it"
  assert_podman_args_lack "$CASE_LOG" \
    'token-value' \
    "podman backend passes the token as a file, never on a command line"
}

test_podman_host_docker_is_opt_in() {
  local socket_path=""
  setup_mock_case podman-hostdocker
  socket_path="$CASE_DIR/docker.sock"
  : >"$socket_path"

  CAPSULE_RUNTIME=podman DOCKER_HOST="unix://$socket_path" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true
  assert_podman_args_lack "$CASE_LOG" \
    '/var/lib/capsule/docker.sock' \
    "the Capsule is isolated from the host daemon by default"

  CAPSULE_RUNTIME=podman DOCKER_HOST="unix://$socket_path" \
    run_capsule "$CASE_BIN" "$CASE_DIR/with" --host-docker true
  assert_podman_args_contain "$CASE_DIR/with" \
    "${socket_path}:/var/lib/capsule/docker.sock" \
    "--host-docker binds the host daemon socket deliberately"

  CAPSULE_RUNTIME=podman CAPSULE_HOST_DOCKER=1 \
    DOCKER_HOST="unix://$socket_path" \
    run_capsule "$CASE_BIN" "$CASE_DIR/with-env" true
  assert_podman_args_contain "$CASE_DIR/with-env" \
    "${socket_path}:/var/lib/capsule/docker.sock" \
    "CAPSULE_HOST_DOCKER enables --host-docker"
}

test_podman_host_docker_without_a_socket_is_an_error() {
  setup_mock_case podman-hostdocker-missing

  if CAPSULE_RUNTIME=podman DOCKER_HOST="unix://$CASE_DIR/absent.sock" \
    run_capsule "$CASE_BIN" "$CASE_LOG" --host-docker true 2>"$CASE_ERR"; then
    fail "--host-docker without a socket is refused"
  else
    pass "--host-docker without a socket is refused"
  fi
  assert_file_contains "$CASE_ERR" \
    'found no Docker socket' \
    "the --host-docker error says what was missing"
}

test_podman_build_uses_docker_format_and_a_secret() {
  setup_mock_case podman-build

  CAPSULE_RUNTIME=podman GITHUB_API_TOKEN=token-value CAPSULE_WITH_DOCKERD=1 \
    run_capsule "$CASE_BIN" "$CASE_LOG" --build --no-cache true

  assert_podman_args_contain "$CASE_LOG" \
    'build --format docker' \
    "podman build keeps Docker format, so the SHELL directive still applies"
  assert_podman_args_contain "$CASE_LOG" \
    '--secret id=github_api_token,env=GITHUB_API_TOKEN' \
    "podman build takes the token as a build secret"
  assert_podman_args_contain "$CASE_LOG" \
    '--build-arg CAPSULE_WITH_DOCKERD=1' \
    "podman build forwards the dockerd build arg"
  assert_podman_args_contain "$CASE_LOG" \
    '--no-cache' \
    "podman build honours --no-cache"
  assert_podman_args_lack "$CASE_LOG" \
    'token-value' \
    "podman build keeps the token off the command line"
}

test_podman_backend_requires_built_image() {
  setup_mock_case podman-noimage

  if CAPSULE_RUNTIME=podman MOCK_PODMAN_NO_IMAGE=1 \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"; then
    fail "podman backend refuses to run an image that was never built"
  else
    pass "podman backend refuses to run an image that was never built"
  fi
  assert_file_contains "$CASE_ERR" \
    'capsule build' \
    "podman backend names the build command in the error"
}

test_podman_falls_back_when_rootful() {
  setup_mock_case podman-rootful

  CAPSULE_RUNTIME=podman MOCK_PODMAN_INFO="false 2" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'podman is running rootful' \
    "a rootful podman falls back rather than run the Capsule as root"
  assert_file_contains "$CASE_LOG" \
    'compose' \
    "the fallback actually runs the Docker backend"
}

test_podman_falls_back_without_a_subid_range() {
  setup_mock_case podman-nosubid

  CAPSULE_RUNTIME=podman MOCK_PODMAN_INFO="true 1" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'no sub-id range' \
    "a user with no sub-id range falls back and names the package"
}

test_podman_falls_back_when_engine_unreachable() {
  setup_mock_case podman-unreachable

  CAPSULE_RUNTIME=podman MOCK_PODMAN_INFO_FAIL=1 \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'podman cannot reach a working engine' \
    "an unreachable engine falls back with the diagnostic named"
}

test_podman_falls_back_for_remote_and_custom_compose() {
  local compose_file=""
  setup_mock_case podman-fallbacks
  compose_file="$CASE_DIR/custom.yml"
  printf 'services:\n  cli:\n    image: custom:latest\n' >"$compose_file"

  CAPSULE_EXTRA_APPROVALS='ssh://remote-host/srv/project' \
    CAPSULE_RUNTIME=podman MOCK_SSH_OUTPUT=1234 \
    run_capsule "$CASE_BIN" "$CASE_LOG" \
    --remote remote-host:/srv/project true 2>"$CASE_ERR"
  assert_file_contains "$CASE_ERR" \
    '--remote needs a Docker daemon' \
    "--remote falls back to Docker with the reason named"

  CAPSULE_RUNTIME=podman CAPSULE_CUSTOM_COMPOSE="$compose_file" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"
  assert_file_contains "$CASE_ERR" \
    'custom compose file needs the Docker backend' \
    "a compose override falls back to Docker with the reason named"
}

test_podman_on_macos_requires_workspace_under_home() {
  setup_mock_case podman-macos
  mkdir -p "$CASE_DIR/home" "$CASE_DIR/elsewhere"

  CAPSULE_RUNTIME=podman MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
    CAPSULE_WORKDIR="$CASE_DIR/elsewhere" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'podman machine cannot see it' \
    "a workspace the podman machine cannot see falls back to Docker"
}

test_podman_on_macos_runs_a_workspace_under_home() {
  setup_mock_case podman-macos-ok
  mkdir -p "$CASE_DIR/home/project"

  CAPSULE_RUNTIME=podman MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
    CAPSULE_WORKDIR="$CASE_DIR/home/project" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_podman_args_contain "$CASE_LOG" \
    'run --rm' \
    "a workspace under the home runs through podman on macOS"
  assert_file_not_contains "$CASE_ERR" \
    'not using podman' \
    "nothing falls back when the machine can see the workspace"
}

test_runtime_docker_keeps_docker_with_podman_available() {
  setup_mock_case podman-pinned-docker

  CAPSULE_RUNTIME=auto run_capsule "$CASE_BIN" "$CASE_LOG" \
    --runtime docker true 2>"$CASE_ERR"

  assert_file_contains "$CASE_LOG" \
    'compose' \
    "--runtime docker wins over an otherwise usable podman"
  assert_podman_args_lack "$CASE_LOG" \
    'run --rm' \
    "--runtime docker starts no podman container"
  assert_file_not_contains "$CASE_ERR" \
    'not using podman' \
    "--runtime docker explains nothing, because nothing fell back"
}

test_runtime_flag_rejects_bad_values() {
  setup_mock_case podman-badruntime

  if run_capsule "$CASE_BIN" "$CASE_LOG" --runtime kern true 2>"$CASE_ERR"; then
    fail "an unknown runtime is rejected"
  else
    pass "an unknown runtime is rejected"
  fi
  assert_file_contains "$CASE_ERR" \
    'unknown runtime: kern' \
    "the unknown runtime error names the value"

  if run_capsule "$CASE_BIN" "$CASE_LOG" --runtime 2>"$CASE_ERR"; then
    fail "a --runtime without a value is rejected"
  else
    pass "a --runtime without a value is rejected"
  fi

  if run_capsule "$CASE_BIN" "$CASE_LOG" --runtime= true 2>"$CASE_ERR"; then
    fail "an empty --runtime= value is rejected"
  else
    pass "an empty --runtime= value is rejected"
  fi

  if CAPSULE_RUNTIME=kern run_capsule "$CASE_BIN" "$CASE_LOG" true \
    2>"$CASE_ERR"; then
    fail "an unknown CAPSULE_RUNTIME is rejected"
  else
    pass "an unknown CAPSULE_RUNTIME is rejected"
  fi

  if CAPSULE_RUNTIME='' run_capsule "$CASE_BIN" "$CASE_LOG" true \
    2>"$CASE_ERR"; then
    pass "an empty CAPSULE_RUNTIME falls back to the default"
  else
    fail "an empty CAPSULE_RUNTIME falls back to the default"
  fi
}

#-------------------------------------------------------------------------------
# In-Capsule engine router
#
# These run docker/capsule-docker.sh for real against mocked engines: a podman
# that creates its API socket, an optional rootless dockerd that creates its
# own, and a Docker client that answers only for a socket that exists. That is
# enough to assert what the router decides, which is all it does.
#-------------------------------------------------------------------------------

# Build a mock engine environment for the router.
make_router_env() {
  local dir="$1"
  local with_dockerd="${2:-}"
  local tool=""

  mkdir -p "$dir/bin" "$dir/real" "$dir/state"
  ln -sf "$ROUTER_PATH" "$dir/bin/docker"

  # The router runs on a PATH of its own so that a host engine cannot
  # decide a case. A real dockerd-rootless.sh on the caller's PATH would
  # otherwise make the missing-Engine case start that daemon and fail on
  # its timeout instead of on the diagnostic the case asserts. Link in
  # only the utilities the router and these mocks actually call.
  for tool in bash basename cat chmod mkdir pkill rm sleep; do
    ln -sf "$(command -v "$tool")" "$dir/bin/$tool"
  done

  cat >"$dir/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "system" ]] && [[ "${2:-}" == "service" ]]; then
  for arg in "$@"; do
    case "$arg" in
      unix://*) : >"${arg#unix://}" ;;
    esac
  done
  sleep 5
fi
exit 0
EOF

  cat >"$dir/real/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
socket="${DOCKER_HOST#unix://}"
if [[ "${1:-}" == "version" ]]; then
  [[ -e "$socket" ]] || exit 1
  exit 0
fi
printf 'ROUTED=%s ARGS=%s\n' "$socket" "$*" >>"${ROUTER_LOG:?}"
EOF

  if [[ -n "$with_dockerd" ]]; then
    cat >"$dir/bin/dockerd-rootless.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    --host=unix://*) : >"${arg#--host=unix://}" ;;
  esac
done
sleep 5
EOF
    chmod +x "$dir/bin/dockerd-rootless.sh"
  fi

  chmod +x "$dir/bin/podman" "$dir/real/docker"
}

# Run the router under one of its two names.
run_router() {
  local dir="$1"
  local invoked_as="$2"
  shift 2

  if [[ "$invoked_as" == "docker" ]]; then
    PATH="$dir/bin" CAPSULE_ENGINE_DIR="$dir/state" \
      CAPSULE_REAL_DOCKER="$dir/real/docker" \
      CAPSULE_HOST_SOCKET="$dir/hostsock" \
      ROUTER_LOG="$dir/routed" \
      "$dir/bin/docker" "$@"
    return
  fi

  PATH="$dir/bin" CAPSULE_ENGINE_DIR="$dir/state" \
    CAPSULE_REAL_DOCKER="$dir/real/docker" \
    CAPSULE_HOST_SOCKET="$dir/hostsock" \
    ROUTER_LOG="$dir/routed" \
    bash "$ROUTER_PATH" "$@"
}

# Stop the mock engines a router case left running.
stop_router_env() {
  local dir="$1"

  run_router "$dir" capsule-docker stop >/dev/null 2>&1 || true
  pkill -f "$dir/bin/podman" 2>/dev/null || true
  pkill -f "$dir/bin/dockerd-rootless.sh" 2>/dev/null || true
}

test_router_starts_the_podman_socket_on_first_use() {
  local dir="$TEST_TMPDIR/router-lazy"
  make_router_env "$dir"

  run_router "$dir" capsule-docker status >"$dir/status" 2>&1 || true
  assert_file_contains "$dir/status" \
    'podman api socket: stopped' \
    "nothing runs in the Capsule until a container command is issued"

  run_router "$dir" docker ps >/dev/null 2>"$dir/err" || true
  assert_file_contains "$dir/err" \
    'starting podman API socket (first use)' \
    "the first docker command starts the podman API socket"
  assert_file_contains "$dir/routed" \
    "ROUTED=$dir/state/podman.sock ARGS=ps" \
    "the command is routed to the podman socket"

  run_router "$dir" docker ps >/dev/null 2>"$dir/err2" || true
  assert_file_not_contains "$dir/err2" \
    'first use' \
    "a second command reuses the running socket silently"

  stop_router_env "$dir"
}

test_router_reports_engine_status() {
  local dir="$TEST_TMPDIR/router-status"
  make_router_env "$dir"

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker status >"$dir/status" 2>&1 || true

  assert_file_contains "$dir/status" \
    'engine: podman' \
    "status names the selected engine"
  assert_file_contains "$dir/status" \
    'podman api socket: running' \
    "status reports the socket it started"
  assert_file_contains "$dir/status" \
    'dockerd: stopped' \
    "status reports the Engine as stopped when it was never asked for"

  stop_router_env "$dir"
}

test_router_switch_to_dockerd_sticks() {
  local dir="$TEST_TMPDIR/router-dockerd"
  make_router_env "$dir" with-dockerd

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker use-dockerd >"$dir/switch" 2>&1 || true
  assert_file_contains "$dir/switch" \
    'engine: dockerd' \
    "use-dockerd reports the engine it switched to"

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  assert_file_contains "$dir/routed" \
    "ROUTED=$dir/state/dockerd.sock" \
    "later commands go to the Engine for the life of the Capsule"

  run_router "$dir" capsule-docker use-podman >/dev/null 2>&1 || true
  : >"$dir/routed"
  run_router "$dir" docker ps >/dev/null 2>&1 || true
  assert_file_contains "$dir/routed" \
    "ROUTED=$dir/state/podman.sock" \
    "use-podman switches back to the socket engine"

  stop_router_env "$dir"
}

test_router_reports_a_missing_dockerd() {
  local dir="$TEST_TMPDIR/router-nodockerd"
  make_router_env "$dir"

  if run_router "$dir" capsule-docker use-dockerd >"$dir/out" 2>&1; then
    fail "use-dockerd fails when the image has no Engine"
  else
    pass "use-dockerd fails when the image has no Engine"
  fi
  assert_file_contains "$dir/out" \
    'rebuild with CAPSULE_WITH_DOCKERD=1' \
    "the missing-Engine error says how to get one"

  stop_router_env "$dir"
}

test_router_prefers_a_bound_host_socket() {
  local dir="$TEST_TMPDIR/router-hostsock"
  make_router_env "$dir"
  : >"$dir/hostsock"

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  assert_file_contains "$dir/routed" \
    "ROUTED=$dir/hostsock" \
    "a deliberately bound host socket wins over the Capsule's own engine"
  assert_file_not_contains "$dir/routed" \
    'podman.sock' \
    "the Capsule's own engine is not started when the host daemon is bound"

  run_router "$dir" capsule-docker status >"$dir/status" 2>&1 || true
  assert_file_contains "$dir/status" \
    'host docker socket' \
    "status says when the host daemon is what answers"

  stop_router_env "$dir"
}

test_router_ignores_a_dead_host_socket() {
  local dir="$TEST_TMPDIR/router-deadsock"
  make_router_env "$dir"

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  assert_file_contains "$dir/routed" \
    "ROUTED=$dir/state/podman.sock" \
    "an absent host socket falls through to the Capsule's own engine"

  stop_router_env "$dir"
}

test_router_stop_releases_the_engines() {
  local dir="$TEST_TMPDIR/router-stop"
  make_router_env "$dir"

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker stop >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker status >"$dir/status" 2>&1 || true

  assert_file_contains "$dir/status" \
    'podman api socket: stopped' \
    "stop leaves no engine running"

  stop_router_env "$dir"
}

test_entrypoint_non_root_path_execs_the_command() {
  local dir="$TEST_TMPDIR/entrypoint-nonroot"
  mkdir -p "$dir/bin"
  cat >"$dir/bin/getent" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$dir/bin/getent"

  # shellcheck disable=SC2016
  if env -u HOME -u USER -u LOGNAME \
    PATH="$dir/bin:$PATH" \
    "$ENTRYPOINT_PATH" bash -c \
    'printf "ENTRYPOINT_EXEC_OK %s %s %s\n" "$HOME" "$USER" "$LOGNAME"' \
    >"$dir/out" 2>"$dir/err"; then
    pass "the entrypoint's non-root path runs the command"
  else
    fail "the entrypoint's non-root path runs the command"
  fi
  assert_file_contains "$dir/out" \
    'ENTRYPOINT_EXEC_OK /home/user user user' \
    "the non-root command receives the Capsule user environment"
}

# shellcheck disable=SC2016
test_podman_image_contract() {
  assert_file_contains "$DOCKERFILE_PATH" \
    'aardvark-dns catatonit fuse-overlayfs netavark nftables passt podman' \
    "Dockerfile installs what the inner engine needs to serve a project"
  assert_file_contains "$DOCKERFILE_PATH" \
    "printf 'user:%s:%s\\n' \"\${sub_start}\" \"\${sub_count}\" > /etc/subuid" \
    "Dockerfile gives the account a sub-id range for the inner engine"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ln -s /usr/local/bin/capsule-docker /usr/local/bin/docker' \
    "Dockerfile puts the engine router ahead of the real client"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ARG CAPSULE_WITH_DOCKERD=0' \
    "Dockerfile keeps the real Engine behind a build arg"
  assert_file_contains "$DOCKERFILE_PATH" \
    'type=secret,id=github_api_token,required=true' \
    "Dockerfile mounts the build token as a secret file"
  assert_file_not_contains "$DOCKERFILE_PATH" \
    'id=github_api_token,env=GITHUB_API_TOKEN' \
    "Dockerfile does not replace the token file with an environment mount"
  assert_file_contains "$DOCKERFILE_PATH" \
    'cat /run/secrets/github_api_token' \
    "Dockerfile reads the token from the file form both builders serve"
  assert_file_contains "$STORAGE_CONF_PATH" \
    'rootless_storage_path = "/var/lib/capsule/inner/containers"' \
    "inner engine storage points at the per-workspace volume"
}

# shellcheck disable=SC2016
test_entrypoint_non_root_contract() {
  assert_file_contains "$ENTRYPOINT_PATH" \
    'refresh_gh_auth' \
    "entrypoint refreshes gh credentials on both paths"
  assert_file_contains "$ENTRYPOINT_PATH" \
    'if [ "$(id -u)" != "0" ]; then
  set_user_environment
  refresh_gh_auth
  exec "$@"' \
    "the non-root path initializes and authenticates before podman exec"
}

main() {
  if ! bash -n "$SCRIPT_PATH"; then
    fail "capsule.sh has valid shell syntax"
  else
    pass "capsule.sh has valid shell syntax"
  fi

  # Ask shellcheck to run rather than just look it up: a mise shim with no
  # version set is on PATH but errors out the moment it is called.
  if shellcheck --version >/dev/null 2>&1; then
    if ! shellcheck "$SCRIPT_PATH"; then
      fail "capsule.sh has linting errors"
    else
      pass "capsule.sh is lint free"
    fi
  else
    skip "shellcheck unavailable; skipping lint check"
  fi

  test_command_layout
  test_completion_subcommand
  test_compose_contract
  test_dockerfile_tooling_contract
  test_dockerfile_uid_gid_contract
  test_entrypoint_contract
  test_build_flag_runs_build_then_runtime
  test_build_subcommand_builds_without_running
  test_build_subcommand_skips_run_approval
  test_build_subcommand_can_build_only_custom_image
  test_build_subcommand_rejects_conflicting_modes
  test_explicit_run_subcommand_starts_capsule
  test_no_cache_flag_applies_to_build_only
  test_double_dash_keeps_runtime_flags
  test_publish_and_volume_flags_forward_to_runtime
  test_publish_and_volume_env_forward_to_runtime
  test_flag_environment_equivalents
  test_empty_optional_arrays_use_nounset_safe_expansion
  test_check_all_docker_linters_use_capsule_host_workdir
  test_check_all_ignores_an_unusable_linter
  test_check_all_reports_skip_reasons
  test_doctor_reports_each_backend_and_probes_by_running
  test_doctor_names_a_stale_session_bus
  test_build_custom_flag_keeps_runtime_flags
  test_build_flag_without_runtime_args
  test_build_custom_flag_requires_custom_compose
  test_build_and_build_custom_flags_conflict
  test_private_home_flag_uses_user_home_bind_mount
  test_private_home_uses_host_path_map_for_home_dir
  test_private_home_requires_home_mapping_with_host_path_map
  test_remote_flag_requires_target
  test_remote_flag_requires_absolute_workdir_syntax
  test_list_finds_docker_and_podman_capsules
  test_list_queries_remote_docker_without_workdir_or_approval
  test_list_rejects_launch_commands
  test_remote_flag_requires_authorization
  test_run_confirmation_supports_only_once
  test_remote_flag_skips_local_workdir_approval
  test_remote_flag_builds_and_runs_over_ssh
  test_remote_flag_accepts_host_port_syntax
  test_remote_flag_autodetects_docker_gid_over_ssh
  test_remote_private_home_uses_remote_user_home
  test_plain_runtime_without_args
  test_custom_compose_runtime_uses_merged_config
  test_custom_compose_builds_base_then_custom_then_runs
  test_custom_compose_no_cache_builds_only_affect_build_steps
  test_custom_compose_build_custom_then_runs
  test_build_custom_flag_without_runtime_args
  test_build_custom_no_cache_applies_to_custom_build_only
  test_custom_compose_requires_existing_file
  test_custom_compose_requires_readable_file
  test_custom_compose_requires_cli_image
  test_explicit_docker_gid_passthrough
  test_debug_mode_enables_xtrace
  test_uid_gid_autodetect
  test_uid_gid_fallback_when_id_fails
  test_explicit_uid_gid_passthrough
  test_workdir_precedence
  test_host_workdir_defaults_to_current_workdir
  test_host_path_map_remaps_container_workdir
  test_host_path_map_uses_first_match
  test_host_path_map_uses_mapped_allowlist_entry
  test_nested_capsule_uses_host_workdir
  test_nested_private_home_uses_host_visible_home_dir
  test_nested_private_home_requires_host_visible_home_dir
  test_linux_gid_autodetect_from_docker_host
  test_bad_docker_host_falls_back_to_context_socket
  test_macos_staff_gid_override
  test_default_gid_when_detection_fails
  test_podman_backend_runs_container_with_keep_id
  test_nested_capsule_podman_uses_local_workdir
  test_podman_inner_volume_is_per_workspace
  test_podman_backend_translates_publish_and_volume
  test_podman_backend_mounts_the_token_secret
  test_podman_host_docker_is_opt_in
  test_podman_host_docker_without_a_socket_is_an_error
  test_podman_build_uses_docker_format_and_a_secret
  test_podman_backend_requires_built_image
  test_podman_falls_back_when_rootful
  test_podman_falls_back_without_a_subid_range
  test_podman_falls_back_when_engine_unreachable
  test_podman_falls_back_for_remote_and_custom_compose
  test_podman_on_macos_requires_workspace_under_home
  test_podman_on_macos_runs_a_workspace_under_home
  test_runtime_docker_keeps_docker_with_podman_available
  test_runtime_flag_rejects_bad_values
  test_router_starts_the_podman_socket_on_first_use
  test_router_reports_engine_status
  test_router_switch_to_dockerd_sticks
  test_router_reports_a_missing_dockerd
  test_router_prefers_a_bound_host_socket
  test_router_ignores_a_dead_host_socket
  test_router_stop_releases_the_engines
  test_entrypoint_non_root_path_execs_the_command
  test_podman_image_contract
  test_entrypoint_non_root_contract

  printf '\nSummary: %d passed, %d failed, %d skipped\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  if [[ "${#SKIP_REASONS[@]}" -gt 0 ]]; then
    printf 'Skipped:\n'
    printf '  - %s\n' "${SKIP_REASONS[@]}"
  fi
  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
