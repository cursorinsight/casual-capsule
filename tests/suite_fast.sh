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
PROFILE_CORE_PATH="$ROOT_DIR/lib/capsule/profile.sh"
CHECK_ALL_PATH="$ROOT_DIR/tests/check_all.sh"
DOCTOR_PATH="$ROOT_DIR/libexec/capsule/doctor"
CI_PATH="$ROOT_DIR/.github/workflows/ci.yml"
COMPOSE_PATH="$ROOT_DIR/compose.yml"
TOKEN_COMPOSE_PATH="$ROOT_DIR/compose.github-token.yml"
DOCKERFILE_PATH="$ROOT_DIR/Dockerfile"
README_PATH="$ROOT_DIR/README.md"
ENTRYPOINT_PATH="$ROOT_DIR/docker/entrypoint.sh"
ROUTER_PATH="$ROOT_DIR/docker/capsule-docker.sh"
STORAGE_CONF_PATH="$ROOT_DIR/docker/storage.conf"
EXAMPLE_PROJECT_DIR="$ROOT_DIR/tests/fixtures/example-project"
PROFILE_CAPSULE_DIR="$ROOT_DIR/tests/fixtures/profile-capsule"

unset CAPSULE_CUSTOM_COMPOSE
unset CAPSULE_BUILD
unset CAPSULE_BUILD_CUSTOM
unset CAPSULE_COMPOSE_PROJECT_NAME
unset CAPSULE_EXTRA_APPROVALS
unset CAPSULE_GID
unset CAPSULE_HOME_HOST_DIR
unset CAPSULE_HOME_VOLUME
unset CAPSULE_HOST_PATH_MAP
unset CAPSULE_HOST_DOCKER
unset CAPSULE_HOST_WORKDIR
unset CAPSULE_IMAGE
unset CAPSULE_PUBLISH
unset CAPSULE_NO_CACHE
unset CAPSULE_PRIVATE_HOME
unset CAPSULE_PROFILES
unset CAPSULE_REMOTE
unset CAPSULE_RUNTIME
unset CAPSULE_UID
unset CAPSULE_VOLUME
unset CAPSULE_WORKDIR
unset DOCKER_GID
unset DOCKER_CONFIG
unset DOCKER_CONTEXT
unset DOCKER_HOST
unset GITHUB_API_TOKEN
unset CAPSULE_REQUIRE_HOST_DOCKER

BUILD_DIR="$ROOT_DIR/_build/tests"
mkdir -p "$BUILD_DIR"
TEST_TMPDIR="$(mktemp -d "$BUILD_DIR/suite_fast.XXXXXX")"
# Resolve symlinks so paths match what capsule.sh produces via pwd -P.
TEST_TMPDIR="$(CDPATH='' cd -- "$TEST_TMPDIR" && pwd -P)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export XDG_CACHE_HOME="$TEST_TMPDIR/cache"
export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
PROFILE_CACHE_DIR="$XDG_CACHE_HOME/capsule/profiles"

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
  previous=""
  profile_env_file=""
  for argument in "$@"; do
    if [[ "$previous" == "--env-from-file" ]]; then
      profile_env_file="$argument"
      break
    fi
    previous="$argument"
  done
  {
    printf 'ENV_DOCKER_GID=%s\n' "${DOCKER_GID:-}"
    printf 'ENV_DOCKER_HOST=%s\n' "${DOCKER_HOST:-}"
    printf 'ENV_CAPSULE_HOME_HOST_DIR=%s\n' "${CAPSULE_HOME_HOST_DIR:-}"
    printf 'ENV_CAPSULE_HOME_MOUNT=%s\n' "${CAPSULE_HOME_MOUNT:-}"
    printf 'ENV_CAPSULE_WORKDIR=%s\n' "${CAPSULE_WORKDIR:-}"
    printf 'ENV_CAPSULE_HOST_WORKDIR=%s\n' "${CAPSULE_HOST_WORKDIR:-}"
    printf 'ENV_CAPSULE_CUSTOM_DIR=%s\n' "${CAPSULE_CUSTOM_DIR:-}"
    printf 'ENV_CAPSULE_COMPOSE_PROJECT_NAME=%s\n' \
      "${CAPSULE_COMPOSE_PROJECT_NAME:-}"
    printf 'ENV_CAPSULE_UID=%s\n' "${CAPSULE_UID:-}"
    printf 'ENV_CAPSULE_GID=%s\n' "${CAPSULE_GID:-}"
    printf 'ARGS=%s\n' "$*"
    if [[ -n "$profile_env_file" ]]; then
      if ! permissions="$(/usr/bin/stat -c '%a' \
        "$profile_env_file" 2>/dev/null)"; then
        permissions="$(/usr/bin/stat -f '%Lp' "$profile_env_file")"
      fi
      printf 'PROFILE_ENV_FILE=%s\n' "$profile_env_file"
      printf 'PROFILE_ENV_PERMISSIONS=%s\n' "$permissions"
      while IFS= read -r entry; do
        printf 'PROFILE_ENV_ENTRY=%s\n' "$entry"
      done <"$profile_env_file"
    fi
  } >>"${MOCK_LOG:?MOCK_LOG is required}"
  if [[ -n "${MOCK_DOCKER_STDIN_FILE:-}" ]] && \
    [[ " $* " == *" run --rm "* ]]; then
    cat >"$MOCK_DOCKER_STDIN_FILE"
  fi
  if [[ -n "${MOCK_COMPOSE_READY_FILE:-}" ]] && \
    [[ " $* " == *" run --rm "* ]]; then
    printf '%s\n' "$$" >"$MOCK_COMPOSE_READY_FILE"
    trap 'printf "INT\n" >>"$MOCK_COMPOSE_SIGNAL_LOG"; exit 130' INT
    trap 'printf "TERM\n" >>"$MOCK_COMPOSE_SIGNAL_LOG"; exit 143' TERM
    while true; do
      sleep 1
    done
  fi
  exit 0
fi

if [[ "${1:-}" == "build" ]]; then
  printf 'DOCKER_ARGS=%s\n' "$*" >>"${MOCK_LOG:?MOCK_LOG is required}"
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
  printf '%s\n' "${MOCK_PODMAN_INFO:-true ${MOCK_PODMAN_RUNTIME:-crun}}"
  printf 'uid %s\ngid %s\n' \
    "${MOCK_PODMAN_UID_COUNT:-65537}" "${MOCK_PODMAN_GID_COUNT:-65537}"
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
previous=""
profile_env_file=""
for argument in "$@"; do
  if [[ "$previous" == "--env-file" ]]; then
    profile_env_file="$argument"
    break
  fi
  previous="$argument"
done
if [[ -n "$profile_env_file" ]]; then
  if ! permissions="$(/usr/bin/stat -c '%a' \
    "$profile_env_file" 2>/dev/null)"; then
    permissions="$(/usr/bin/stat -f '%Lp' "$profile_env_file")"
  fi
  {
    printf 'PROFILE_ENV_FILE=%s\n' "$profile_env_file"
    printf 'PROFILE_ENV_PERMISSIONS=%s\n' "$permissions"
    while IFS= read -r entry; do
      printf 'PROFILE_ENV_ENTRY=%s\n' "$entry"
    done <"$profile_env_file"
  } >>"${MOCK_LOG:?MOCK_LOG is required}"
fi
if [[ "${1:-}" == "run" && -n "${MOCK_PODMAN_STDIN_FILE:-}" ]]; then
  cat >"$MOCK_PODMAN_STDIN_FILE"
fi
if [[ "${1:-}" == "run" && -n "${MOCK_PODMAN_ENV_FILE:-}" ]]; then
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--env" ]]; then
      printf '%s\n' "$2" >>"$MOCK_PODMAN_ENV_FILE"
      shift
    fi
    shift
  done
fi
exit 0
EOF

  cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_CURL_FAIL:-}" ]]; then
  exit 1
fi
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
    CAPSULE_PROFILES="${CAPSULE_PROFILES-}" \
    CAPSULE_REMOTE="${CAPSULE_REMOTE-}" \
    CAPSULE_VOLUME="${CAPSULE_VOLUME-}" \
    DOCKER_HOST="${DOCKER_HOST-}" \
    CAPSULE_RUNTIME="${CAPSULE_RUNTIME-docker}" \
    "$SCRIPT_PATH" "$@"
}

run_signal_capsule() {
  local mock_bin="$1"
  local log_file="$2"
  local ready_file="$3"
  local signal_file="$4"
  local config_file="$5"
  local profile_dir="${6:-}"

  trap - INT TERM
  export PATH="$mock_bin:$PATH"
  export MOCK_LOG="$log_file"
  export MOCK_COMPOSE_READY_FILE="$ready_file"
  export MOCK_COMPOSE_SIGNAL_LOG="$signal_file"
  export CAPSULE_CONFIG="$config_file"
  export CAPSULE_RUNTIME=docker
  export DOCKER_GID=1111
  if [[ -n "$profile_dir" ]]; then
    export CAPSULE_PROFILES="$profile_dir"
  else
    unset CAPSULE_PROFILES
  fi
  exec "$SCRIPT_PATH" true
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

profile_path_token() {
  local checksum=""

  checksum="$(printf '%s\n' "$@" | cksum | cut -d' ' -f1)"
  printf '%08x\n' "$checksum"
}

profile_generated_file() {
  local token="$1"
  local name="$2"
  local candidate=""
  local found=""

  for candidate in "$PROFILE_CACHE_DIR/$token"/*/"$name"; do
    [[ -f "$candidate" ]] || continue
    [[ -z "$found" ]] || return 1
    found="$candidate"
  done
  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
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
  local config_home="$tdir/config"
  local profile_home="$config_home/capsule/profiles"
  local candidates_file="$tdir/candidates"
  local output_file="$tdir/output"
  local err_file="$tdir/err"
  local log_file="$tdir/log"
  local mock_bin="$tdir/bin"
  local shell=""
  local marker=""
  local profile_marker=""
  local completed_profile=""
  local first_line=""
  mkdir -p \
    "$profile_home/named-test" \
    "$profile_home/nvidia" \
    "$tdir/local-profile"
  make_mock_bin "$mock_bin"
  cat >"$tdir/local-profile/capsule.toml" <<'EOF'
version = 1
name = "local-completion"

[env]
COMPLETED_PROFILE = "enabled"
EOF

  for shell in bash zsh fish; do
    case "$shell" in
      bash)
        marker='complete -o bashdefault'
        profile_marker='--profile'
        ;;
      zsh)
        marker='#compdef capsule'
        profile_marker='*--profile'
        ;;
      fish)
        marker='complete -c capsule'
        profile_marker='-l profile'
        ;;
    esac
    "$CAPSULE_BIN" completion "$shell" >"$output_file"
    assert_file_contains "$output_file" "$marker" \
      "completion generates $shell definitions"
    assert_file_contains "$output_file" "$profile_marker" \
      "$shell completion offers Capsule profiles"
    assert_file_contains "$output_file" "$ROOT_DIR/profiles" \
      "$shell completion includes bundled profiles"
    if [[ "$shell" == "bash" ]]; then
      if bash -n "$output_file"; then
        pass "generated Bash completion has valid syntax"
      else
        fail "generated Bash completion has valid syntax"
      fi
      (
        cd "$tdir"
        XDG_CONFIG_HOME="$config_home" \
          COMPLETION_FILE="$output_file" bash -c '
            source "$COMPLETION_FILE"
            COMP_WORDS=(capsule --profile "")
            COMP_CWORD=2
            _capsule
            printf "%s\n" "${COMPREPLY[@]}"
          '
      ) >"$candidates_file"
      assert_file_contains "$candidates_file" 'named-test' \
        "Bash profile completion offers configured names"
      assert_file_contains "$candidates_file" 'nvidia' \
        "Bash profile completion offers bundled names"
      assert_equals 1 \
        "$(grep -Fxc 'nvidia' "$candidates_file" || true)" \
        "Bash profile completion removes overridden duplicate names"
      assert_file_contains "$candidates_file" './local-profile' \
        "Bash profile completion retains directory paths"
      completed_profile="$(grep -Fx './local-profile' "$candidates_file")"
      (
        cd "$tdir"
        DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
          --profile "$completed_profile" true
      )
      assert_file_contains "$log_file" \
        "PROFILE_ENV_ENTRY=COMPLETED_PROFILE='enabled'" \
        "Bash profile completion emits an accepted directory path"
    fi
    if [[ "$shell" == "zsh" ]]; then
      IFS= read -r first_line <"$output_file"
      assert_equals '#compdef capsule' "$first_line" \
        "Zsh completion starts with its compdef marker"
      assert_file_contains "$output_file" '_capsule_profiles()' \
        "Zsh completion defines configured profile candidates"
      assert_file_contains "$output_file" '_directories' \
        "Zsh profile completion retains directory paths"
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
        'function __fish_capsule_profiles' \
        "Fish completion defines configured profile candidates"
      assert_file_contains "$output_file" '__fish_complete_directories' \
        "Fish profile completion retains directory paths"
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
  assert_file_contains "$TOKEN_COMPOSE_PATH" \
    'environment: GITHUB_API_TOKEN' \
    "compose sources github token from GITHUB_API_TOKEN env"
  assert_file_contains "$TOKEN_COMPOSE_PATH" \
    '- github_api_token' \
    "compose mounts github token as a runtime secret"
  assert_file_not_contains "$COMPOSE_PATH" 'github_api_token' \
    "base compose runs without a GitHub token"
  assert_file_contains "$COMPOSE_PATH" 'CAPSULE_REQUIRE_HOST_DOCKER=1' \
    "Docker backend requires the mounted host socket"
  assert_file_contains "$COMPOSE_PATH" \
    '- MISE_SYSTEM_TOOLS' \
    "compose passes MISE_SYSTEM_TOOLS from the build environment"
  assert_file_contains "$COMPOSE_PATH" \
    '- CAPSULE_WITH_DOCKERD=${CAPSULE_WITH_DOCKERD:-0}' \
    "compose forwards the dockerd build option with a disabled default"
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
    'COPY --chmod=644 docker/remap-storage.c /tmp/capsule-remap-storage.c' \
    "Dockerfile includes the native storage migration source"
  assert_file_contains "$DOCKERFILE_PATH" \
    '-o /usr/local/libexec/capsule/remap-storage' \
    "Dockerfile builds the native storage migration helper"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' \
    "Dockerfile sets entrypoint for runtime UID/GID"
  assert_file_contains "$DOCKERFILE_PATH" \
    'CMD ["/bin/bash", "-il"]' \
    "Dockerfile uses login shell as default command"
}

# shellcheck disable=SC2016
test_entrypoint_contract() {
  local mapping_guard_line=""
  local configuration_line=""

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
    'prepare_inner_storage /var/lib/capsule/inner' \
    "entrypoint repairs inner storage before dropping privileges"
  mapping_guard_line="$(awk \
    '/^check_inner_storage_mapping \/var\/lib\/capsule\/inner$/ \
      {print NR; exit}' "$ENTRYPOINT_PATH")"
  configuration_line="$(awk '/>\/etc\/subuid/ {print NR; exit}' \
    "$ENTRYPOINT_PATH")"
  if [[ -n "$mapping_guard_line" && -n "$configuration_line" &&
    "$mapping_guard_line" -lt "$configuration_line" ]]; then
    pass "storage range guard runs before runtime configuration changes"
  else
    fail "storage range guard runs before runtime configuration changes"
  fi
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
  for tool in bash dirname id uname grep awk; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done

  cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "compose run --help" ]] && \
  [[ "${MOCK_COMPOSE_ENV_FROM_FILE:-1}" -ne 0 ]]; then
  printf '      --env-from-file stringArray\n'
fi
exit 0
EOF

  cat >"$dir/podman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *Rootless*)
    printf 'true runc\nuid %s\ngid %s\n' \
      "${MOCK_PODMAN_UID_COUNT:-65537}" "${MOCK_PODMAN_GID_COUNT:-65537}"
    ;;
  *OCIRuntime.Name*) printf 'runc\n' ;;
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
    'docker compose supports profile environment files' \
    "the doctor probes the required Compose run option"
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

  MOCK_COMPOSE_ENV_FROM_FILE=0 PATH="$bin_dir" \
    "$DOCTOR_PATH" >"$out_file" 2>&1 || true
  assert_file_contains "$out_file" \
    'docker compose lacks run --env-from-file' \
    "the doctor rejects Compose without profile environment support"
  assert_file_contains "$out_file" \
    'upgrade Docker Compose to 2.34.0 or newer' \
    "the doctor reports the minimum supported Compose version"
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

test_test_runner_clears_inherited_runtime() {
  local tdir="$TEST_TMPDIR/test-runner-runtime"
  local suite_name=""
  local runtime=""
  mkdir -p "$tdir/tests"
  cp "$ROOT_DIR/tests/test_all.sh" "$tdir/tests/test_all.sh"
  for suite_name in suite_fast.sh suite_e2e.sh; do
    cat >"$tdir/tests/$suite_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${CAPSULE_RUNTIME+x}" && "${CAPSULE_E2E_STRICT:-}" == "1" ]]
EOF
    chmod +x "$tdir/tests/$suite_name"
  done

  for runtime in docker podman; do
    if CAPSULE_RUNTIME="$runtime" CAPSULE_E2E_STRICT=1 \
      "$tdir/tests/test_all.sh" >/dev/null; then
      pass "test runner clears inherited $runtime while keeping strict mode"
    else
      fail "test runner clears inherited $runtime while keeping strict mode"
    fi
  done
}

# Verify CI exercises a nested Capsule through each supported backend.
# shellcheck disable=SC2016
test_ci_runs_nested_capsules_for_each_backend() {
  test_test_runner_clears_inherited_runtime
  assert_file_contains "$CI_PATH" \
    'name: nested-capsule (${{ matrix.runtime }})' \
    "GitHub CI exposes separate nested backend checks"
  assert_file_contains "$CI_PATH" \
    'runtime:' \
    "GitHub CI defines a nested Capsule runtime matrix"
  assert_file_contains "$CI_PATH" \
    '- docker' \
    "GitHub CI tests a Docker-backed Capsule"
  assert_file_contains "$CI_PATH" \
    '- podman' \
    "GitHub CI tests a Podman-backed Capsule"
  assert_file_contains "$CI_PATH" \
    'CAPSULE_E2E_STRICT=1 tests/test_all.sh' \
    "nested CI rejects skipped backend prerequisites"
  assert_file_contains "$CI_PATH" \
    'reason="$(podman_host_reason "$info")"' \
    "Podman CI requires rootless subordinate ID mappings"
  assert_file_contains "$CI_PATH" \
    'capsule_args+=(--host-docker)' \
    "Podman CI uses host Docker for Compose-specific tests"
  assert_file_contains "$CI_PATH" \
    'run.oci.keep_original_groups=1' \
    "Podman CI preserves group access to the host Docker socket"
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

# Verify --build-custom fails early without a profile or custom Compose.
test_build_custom_flag_requires_custom_compose() {
  local tdir="$TEST_TMPDIR/build-custom-missing-config"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --build-custom true 2>"$err_file"; then
    fail "build-custom flag requires custom configuration"
  else
    pass "build-custom flag requires custom configuration"
  fi
  assert_file_contains "$err_file" \
    "--build-custom requires a profile or CAPSULE_CUSTOM_COMPOSE" \
    "build-custom flag reports a clear missing configuration error"
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

test_list_debug_trace_hides_container_secrets() {
  local tdir="$TEST_TMPDIR/list-debug-secrets"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local out_file="$tdir/out"
  local err_file="$tdir/err"
  local secret="container-secret-must-not-leak"
  local docker_inspect="UNRELATED_SECRET=$secret"
  docker_inspect+=$'\nCAPSULE_HOST_WORKDIR=/srv/debug\nCAPSULE_UID=1000'
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  CAPSULE_DEBUG=1 CAPSULE_RUNTIME=docker \
    MOCK_DOCKER_PS=$'debug-id\tdebug-capsule\t1 minute\timage:d\tUp\t' \
    MOCK_DOCKER_INSPECT="$docker_inspect" \
    run_capsule "$mock_bin" "$log_file" list \
    >"$out_file" 2>"$err_file"

  assert_file_contains "$out_file" '/srv/debug' \
    "debug list still reads the selected container environment value"
  assert_file_not_contains "$err_file" "$secret" \
    "debug list does not trace unrelated container secrets"
}

test_list_labels_implicit_remote_docker_endpoints() {
  local tdir="$TEST_TMPDIR/list-implicit-remote"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local host_out="$tdir/host-out"
  local context_out="$tdir/context-out"
  local docker_ps=$'remote-id\tremote-capsule\t3 days\timage:r\tUp\t'
  local docker_inspect=$'CAPSULE_HOST_WORKDIR=/remote/project\n'
  docker_inspect+='CAPSULE_UID=2000'
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  DOCKER_HOST=tcp://builder:2376 CAPSULE_RUNTIME=docker \
    MOCK_DOCKER_PS="$docker_ps" \
    MOCK_DOCKER_INSPECT="$docker_inspect" MOCK_ID_USER=wrong-local-user \
    run_capsule "$mock_bin" "$log_file" list >"$host_out"
  assert_file_contains "$host_out" 'tcp://builder:2376' \
    "list labels a remote DOCKER_HOST endpoint"
  assert_file_not_contains "$host_out" 'wrong-local-user' \
    "list does not resolve a remote UID against local accounts"
  assert_file_contains "$host_out" '2000' \
    "list reports the recorded UID for an implicit remote endpoint"

  DOCKER_CONTEXT=builder-context CAPSULE_RUNTIME=docker \
    MOCK_CONTEXT_HOST=ssh://context-builder \
    MOCK_DOCKER_PS="$docker_ps" MOCK_DOCKER_INSPECT="$docker_inspect" \
    MOCK_ID_USER=wrong-local-user \
    run_capsule "$mock_bin" "$log_file" list >"$context_out"
  assert_file_contains "$context_out" 'ssh://context-builder' \
    "list labels the active remote Docker context"
  assert_file_not_contains "$context_out" 'wrong-local-user' \
    "list avoids local UID lookup for a remote Docker context"
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

test_default_config_uses_xdg_location() {
  local tdir="$TEST_TMPDIR/xdg-config"
  local config_home="$tdir/config"
  local approval_file="$config_home/capsule/approved-directories"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$(dirname -- "$approval_file")"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$ROOT_DIR" >"$approval_file"

  if env -u CAPSULE_CONFIG XDG_CONFIG_HOME="$config_home" \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_RUNTIME=docker DOCKER_GID=1111 \
    "$SCRIPT_PATH" true; then
    pass "default approval list uses XDG_CONFIG_HOME"
  else
    fail "default approval list uses XDG_CONFIG_HOME"
  fi
}

test_relative_xdg_paths_are_rejected() {
  local tdir="$TEST_TMPDIR/relative-xdg"
  local project_dir="$tdir/project"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local variable=""
  mkdir -p "$project_dir/.config/capsule"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$project_dir" \
    >"$project_dir/.config/capsule/approved-directories"

  for variable in XDG_CONFIG_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR; do
    : >"$err_file"
    if (
      cd "$project_dir"
      env -u CAPSULE_CONFIG "$variable=.config" \
        PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
        CAPSULE_RUNTIME=docker DOCKER_GID=1111 \
        "$SCRIPT_PATH" true
    ) >"$tdir/out" 2>"$err_file"; then
      fail "$variable rejects a relative path"
    else
      pass "$variable rejects a relative path"
    fi
    assert_file_contains "$err_file" \
      "$variable must be an absolute path" \
      "$variable explains its absolute-path requirement"
  done
}

test_legacy_config_is_migrated() {
  local tdir="$TEST_TMPDIR/legacy-config"
  local home_dir="$tdir/home"
  local legacy_path="$home_dir/.config/capsule"
  local approval_file="$legacy_path/approved-directories"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$home_dir/.config"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$ROOT_DIR" >"$legacy_path"

  if env -u CAPSULE_CONFIG XDG_CONFIG_HOME="$home_dir/.config/" \
    HOME="$home_dir" \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_RUNTIME=docker DOCKER_GID=1111 \
    "$SCRIPT_PATH" true 2>"$tdir/err"; then
    pass "legacy approval list remains usable after migration"
  else
    fail "legacy approval list remains usable after migration"
  fi
  assert_file_contains "$approval_file" "$ROOT_DIR" \
    "legacy approval list moves under the config directory"
}

test_legacy_config_symlink_is_rejected() {
  local tdir="$TEST_TMPDIR/legacy-config-symlink"
  local home_dir="$tdir/home"
  local legacy_path="$home_dir/.config/capsule"
  local target_file="$home_dir/.config/approvals"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$home_dir/.config"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$ROOT_DIR" >"$target_file"
  ln -s approvals "$legacy_path"

  if env -u CAPSULE_CONFIG -u XDG_CONFIG_HOME HOME="$home_dir" \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_RUNTIME=docker DOCKER_GID=1111 \
    "$SCRIPT_PATH" true 2>"$err_file"; then
    fail "legacy approval symlinks require manual migration"
  else
    pass "legacy approval symlinks require manual migration"
  fi
  assert_file_contains "$err_file" \
    'replace legacy config symlink with a regular approval file' \
    "legacy symlink reports actionable migration guidance"
  if [[ -L "$legacy_path" ]]; then
    pass "rejected legacy approval symlink remains in place"
  else
    fail "rejected legacy approval symlink remains in place"
  fi
  assert_file_contains "$target_file" "$ROOT_DIR" \
    "rejected legacy approval symlink target remains unchanged"
}

test_legacy_config_migration_resumes() {
  local tdir="$TEST_TMPDIR/legacy-config-resume"
  local home_dir="$tdir/home"
  local legacy_path="$home_dir/.config/capsule"
  local recovery_file="${legacy_path}.migration"
  local approval_file="$legacy_path/approved-directories"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$legacy_path"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$ROOT_DIR" >"$recovery_file"

  if env -u CAPSULE_CONFIG -u XDG_CONFIG_HOME HOME="$home_dir" \
    PATH="$mock_bin:$PATH" MOCK_LOG="$log_file" \
    CAPSULE_RUNTIME=docker DOCKER_GID=1111 \
    "$SCRIPT_PATH" true 2>"$tdir/err"; then
    pass "interrupted legacy approval migration resumes"
  else
    fail "interrupted legacy approval migration resumes"
  fi
  assert_file_contains "$approval_file" "$ROOT_DIR" \
    "resumed migration restores the approval list"
  if [[ ! -e "$recovery_file" ]]; then
    pass "resumed migration consumes the recovery file"
  else
    fail "resumed migration consumes the recovery file"
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

test_debug_mode_redacts_github_token() {
  local forwarded_token='capsule-synthetic-forwarded-token'
  local profile_dir=""
  local runtime=""
  local token='capsule-synthetic-debug-token'
  setup_mock_case debug-token
  profile_dir="$CASE_DIR/profile"
  mkdir -p "$CASE_DIR/home" "$profile_dir"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "debug-token"

[env]
FORWARDED_TOKEN = "${PROFILE_SOURCE_TOKEN}"

[dockerfile]
content = '''
ENV DEBUG_TOKEN_PROFILE=1
'''
EOF

  for runtime in docker podman; do
    CAPSULE_DEBUG=1 CAPSULE_RUNTIME="$runtime" GITHUB_API_TOKEN="$token" \
      CAPSULE_PROFILES="$profile_dir" HOME="$CASE_DIR/home" \
      PROFILE_SOURCE_TOKEN="$forwarded_token" \
      run_capsule "$CASE_BIN" "$CASE_DIR/$runtime-log" --build true \
      >"$CASE_DIR/$runtime-out" 2>"$CASE_DIR/$runtime-err"
    assert_file_not_contains "$CASE_DIR/$runtime-err" "$token" \
      "$runtime debug trace never exposes the GitHub token"
    assert_file_not_contains "$CASE_DIR/$runtime-out" "$token" \
      "$runtime output never exposes the GitHub token"
    assert_file_not_contains "$CASE_DIR/$runtime-log" "$token" \
      "$runtime invocations never contain the GitHub token"
    assert_file_not_contains "$CASE_DIR/$runtime-err" "$forwarded_token" \
      "$runtime debug trace never exposes a forwarded token"
    assert_file_not_contains "$CASE_DIR/$runtime-out" "$forwarded_token" \
      "$runtime output never exposes a forwarded token"
    assert_file_contains "$CASE_DIR/$runtime-log" "$forwarded_token" \
      "$runtime profile environment receives the forwarded token"
    assert_file_contains "$CASE_DIR/$runtime-err" '+ set -euo pipefail' \
      "$runtime debugging remains enabled with a token"
    assert_file_contains "$CASE_DIR/$runtime-err" \
      '+ cleanup_runtime_state' \
      "$runtime tracing resumes after writing the profile environment"
    assert_file_contains "$CASE_DIR/$runtime-log" \
      '--secret id=github_api_token,env=GITHUB_API_TOKEN' \
      "$runtime profile build receives the protected token"
  done
  assert_file_contains "$CASE_DIR/podman-err" '+ cleanup_podman_state' \
    "Podman restores parent tracing after writing its secret"
}

test_token_presence_checks_do_not_expand_values() {
  if grep -Eq '\$\{[A-Z_][A-Z0-9_]*TOKEN:-' \
    "$CORE_PATH" "$PROFILE_CORE_PATH"; then
    fail "xtrace-enabled token checks avoid value expansion"
  else
    pass "xtrace-enabled token checks avoid value expansion"
  fi
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

test_profile_runtime_settings() {
  local tdir="$TEST_TMPDIR/profile-runtime"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local override_file=""
  local profile_env_file=""
  mkdir -p "$profile_dir/data"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "runtime-test"
namespace = "runtime"
volume = [
  "./data:/profile-data:ro",
]
publish = ["8080:80"]
host = ["example.internal=192.0.2.10"]

[env]
SAME_VALUE = "${SAME_VALUE}"
RENAMED_VALUE = "${SOURCE_VALUE}"
COMPLEX_VALUE = "${SOURCE_COMPLEX_VALUE}"
TRAILING_VALUE = "${SOURCE_TRAILING_VALUE}"
FIXED_VALUE = "enabled"
DOCKER_HOST = "container-only"
UNSET_VALUE = "${MISSING_VALUE}"
LITERAL_VALUE = "$${SOURCE_VALUE}"
EOF

  (
    export SAME_VALUE="same"
    export SOURCE_VALUE="renamed"
    export SOURCE_COMPLEX_VALUE="^\\d+\$ and it's"
    export SOURCE_TRAILING_VALUE=$'line\n'
    CAPSULE_PROFILES="$profile_dir" DOCKER_GID=1111 \
      run_capsule "$mock_bin" "$log_file" --build true
  )
  override_file="$(
    profile_generated_file \
      "$(profile_path_token "$profile_dir")" compose.yml
  )"

  assert_file_not_contains "$log_file" '--env SAME_VALUE=same' \
    "profile keeps forwarded values out of Docker arguments"
  assert_file_contains "$log_file" "PROFILE_ENV_ENTRY=SAME_VALUE='same'" \
    "profile forwards an environment variable under the same name"
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=RENAMED_VALUE='renamed'" \
    "profile forwards an environment variable under a new name"
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=COMPLEX_VALUE='^\\d+\$ and it\\'s'" \
    "Docker environment preserves backslashes and apostrophes"
  if grep -Fxq "PROFILE_ENV_ENTRY='" "$log_file"; then
    pass "Docker environment preserves a trailing newline"
  else
    fail "Docker environment loses a trailing newline"
  fi
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=FIXED_VALUE='enabled'" \
    "profile sets a literal environment value"
  assert_file_not_contains "$log_file" 'PROFILE_ENV_ENTRY=UNSET_VALUE=' \
    "profile leaves an unset referenced environment variable unset"
  # The marker is intentionally literal.
  # shellcheck disable=SC2016
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=LITERAL_VALUE='\${SOURCE_VALUE}'" \
    "profile escapes a literal interpolation marker"
  assert_file_contains "$log_file" '--env-from-file ' \
    "Docker reads profile environment from a private file"
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=DOCKER_HOST='container-only'" \
    "profile environment can use a Docker client variable name"
  assert_file_contains "$log_file" 'ENV_DOCKER_HOST=' \
    "profile environment does not alter the Docker client"
  assert_file_contains "$log_file" 'PROFILE_ENV_PERMISSIONS=600' \
    "profile environment file is owner-readable only"
  profile_env_file="$(value_from_log PROFILE_ENV_FILE "$log_file")"
  if [[ -n "$profile_env_file" && ! -e "$profile_env_file" ]]; then
    pass "profile environment file is removed after Docker exits"
  else
    fail "profile environment file remains after Docker exits"
  fi
  assert_file_contains "$log_file" '--publish 8080:80' \
    "profile forwards published ports"
  assert_file_not_contains "$log_file" '--add-host' \
    "Docker profile avoids unsupported host mapping flags"
  assert_file_contains "$log_file" \
    "--volume $profile_dir/data:/profile-data:ro" \
    "profile resolves relative volumes against its directory"
  assert_file_not_contains "$log_file" '-profile-' \
    "runtime-only profile does not replace the Capsule image"
  assert_file_contains "$log_file" \
    'ENV_CAPSULE_COMPOSE_PROJECT_NAME=casual-capsule-runtime' \
    "profile namespace isolates the Docker Compose project"
  assert_file_contains "$log_file" \
    'ARGS=compose --project-name casual-capsule -f' \
    "profile namespace builds the stable Docker base project"
  assert_file_contains "$log_file" \
    "ARGS=compose --project-name casual-capsule-runtime -f" \
    "profile namespace uses the namespaced runtime project"
  assert_file_contains "$override_file" \
    'image: casual-capsule-cli:latest' \
    "profile namespace keeps the Docker base image stable"
  assert_file_contains "$override_file" 'extra_hosts:' \
    "Docker profile declares static host mappings in Compose"
  assert_file_contains "$override_file" \
    "- 'example.internal=192.0.2.10'" \
    "Docker profile writes its static host mapping"

  GITHUB_API_TOKEN=token-value CAPSULE_PROFILES="$profile_dir" \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$tdir/token-log" --build true
  assert_file_contains "$tdir/token-log" \
    "--project-name casual-capsule -f $COMPOSE_PATH -f $TOKEN_COMPOSE_PATH" \
    "profile base build retains the supplied token override"
  assert_file_contains "$tdir/token-log" \
    "-f $TOKEN_COMPOSE_PATH -f $override_file run --rm" \
    "profile runtime retains the supplied token override"

  if SOURCE_TRAILING_VALUE=$'line\n' CAPSULE_PROFILES="$profile_dir" \
    CAPSULE_RUNTIME=podman run_capsule "$mock_bin" "$log_file" true \
    2>"$err_file"; then
    fail "Podman accepts a forwarded environment newline"
  else
    pass "Podman rejects a forwarded environment newline"
  fi
  assert_file_contains "$err_file" \
    'profile environment value contains a newline: TRAILING_VALUE' \
    "Podman reports the forwarded environment newline"
}

test_profile_honors_compose_project_name() {
  local tdir="$TEST_TMPDIR/profile-compose-project"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local override_file=""
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "compose-project"
namespace = "runtime"

[dockerfile]
content = '''
ENV COMPOSE_PROJECT_PROFILE=1
'''
EOF

  COMPOSE_PROJECT_NAME=inherited-project \
    CAPSULE_COMPOSE_PROJECT_NAME=ignored-project \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --build --profile "$profile_dir" true
  override_file="$(
    profile_generated_file \
      "$(profile_path_token "$profile_dir")" compose.yml
  )"

  assert_file_contains "$log_file" \
    'ARGS=compose --project-name inherited-project -f' \
    "Compose project environment selects the profile base project"
  assert_file_contains "$log_file" \
    '--build-arg CAPSULE_BASE_IMAGE=inherited-project-cli:latest' \
    "profile build extends the effective Compose base image"
  assert_file_contains "$override_file" \
    'image: inherited-project-runtime-profile-compose-project-' \
    "profile image uses the effective namespaced project"
  assert_file_contains "$log_file" \
    'ARGS=compose --project-name inherited-project-runtime -f' \
    "profile runtime pins the effective namespaced project"
}

test_docker_profile_preserves_piped_stdin() {
  local tdir="$TEST_TMPDIR/docker-profile-stdin"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "stdin-test"

[env]
STDIN_TEST = "enabled"
EOF

  printf 'capsule piped payload\n' |
    MOCK_DOCKER_STDIN_FILE="$tdir/stdin" DOCKER_GID=1111 \
      run_capsule "$mock_bin" "$log_file" \
      --profile "$profile_dir" cat

  assert_file_contains "$tdir/stdin" 'capsule piped payload' \
    "Docker profile preserves piped stdin"
}

test_docker_runtime_forwards_signals() {
  local tdir="$TEST_TMPDIR/docker-signals"
  local mock_bin="$tdir/bin"
  local profile_dir="$tdir/profile"
  local config_file="$tdir/config"
  local launcher_pid=""
  local runtime_pid=""
  local profile_env_file=""
  local exit_code=0
  local attempt=0
  local signal=""
  local expected_status=0
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"
  printf '%s\n' "$(pwd -P)" >"$config_file"

  run_signal_capsule \
    "$mock_bin" \
    "$tdir/direct-log" \
    "$tdir/direct-ready" \
    "$tdir/direct-signal" \
    "$config_file" &
  launcher_pid=$!
  for ((attempt = 0; attempt < 50; attempt++)); do
    [[ -s "$tdir/direct-ready" ]] && break
    sleep 0.1
  done
  if [[ -s "$tdir/direct-ready" ]]; then
    pass "Docker runtime starts for direct signal delivery"
  else
    fail "Docker runtime starts for direct signal delivery"
    kill -TERM "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    return
  fi
  runtime_pid="$(cat "$tdir/direct-ready")"
  assert_equals "$launcher_pid" "$runtime_pid" \
    "Docker runtime replaces the launcher when cleanup is unnecessary"
  kill -TERM "$launcher_pid"
  if wait "$launcher_pid"; then
    exit_code=0
  else
    exit_code=$?
  fi
  assert_equals 143 "$exit_code" \
    "direct Docker runtime returns its termination status"
  assert_file_contains "$tdir/direct-signal" TERM \
    "direct Docker runtime receives the launcher's termination signal"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "signal-test"

[env]
SIGNAL_TEST = "enabled"
EOF

  for signal in INT TERM; do
    case "$signal" in
      INT) expected_status=130 ;;
      TERM) expected_status=143 ;;
    esac
    run_signal_capsule \
      "$mock_bin" \
      "$tdir/$signal-log" \
      "$tdir/$signal-ready" \
      "$tdir/$signal-received" \
      "$config_file" \
      "$profile_dir" &
    launcher_pid=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
      [[ -s "$tdir/$signal-ready" ]] && break
      sleep 0.1
    done
    if [[ -s "$tdir/$signal-ready" ]]; then
      pass "supervised Docker runtime starts for $signal forwarding"
    else
      fail "supervised Docker runtime starts for $signal forwarding"
      kill -TERM "$launcher_pid" 2>/dev/null || true
      wait "$launcher_pid" 2>/dev/null || true
      continue
    fi
    runtime_pid="$(cat "$tdir/$signal-ready")"
    if [[ "$launcher_pid" != "$runtime_pid" ]]; then
      pass "profile environment keeps a supervising launcher for $signal"
    else
      fail "profile environment keeps a supervising launcher for $signal"
    fi
    kill -"$signal" "$launcher_pid"
    if wait "$launcher_pid"; then
      exit_code=0
    else
      exit_code=$?
    fi
    assert_equals "$expected_status" "$exit_code" \
      "supervised Docker runtime returns the $signal status"
    assert_file_contains "$tdir/$signal-received" "$signal" \
      "supervised Docker runtime forwards $signal"
    profile_env_file="$(
      value_from_log PROFILE_ENV_FILE "$tdir/$signal-log"
    )"
    if [[ -n "$profile_env_file" && ! -e "$profile_env_file" ]]; then
      pass "supervised Docker runtime cleans its file after $signal"
    else
      fail "supervised Docker runtime cleans its file after $signal"
    fi
  done
}

test_profile_names_resolve_from_xdg_config() {
  local tdir="$TEST_TMPDIR/profile-name"
  local config_home="$tdir/config"
  local profile_dir="$config_home/capsule/profiles/named-test"
  local local_profile_dir="$tdir/named-test"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local selector=""
  local work_dir=""
  mkdir -p "$profile_dir" "$local_profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "named-test"

[env]
NAMED_PROFILE = "enabled"
EOF

  cat >"$local_profile_dir/capsule.toml" <<'EOF'
version = 1
name = "local-test"

[env]
LOCAL_PROFILE = "enabled"
EOF

  (
    cd "$tdir"
    XDG_CONFIG_HOME="$config_home" CAPSULE_PROFILES=named-test \
      DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
  )

  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=NAMED_PROFILE='enabled'" \
    "bare profile selectors resolve names from XDG_CONFIG_HOME"
  assert_file_not_contains "$log_file" \
    "PROFILE_ENV_ENTRY=LOCAL_PROFILE='enabled'" \
    "bare profile selectors ignore same-named working directories"

  : >"$log_file"
  (
    cd "$tdir"
    XDG_CONFIG_HOME="$config_home" CAPSULE_PROFILES=./named-test \
      DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
  )
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=LOCAL_PROFILE='enabled'" \
    "explicit relative paths select working-directory profiles"

  mkdir -p "$local_profile_dir/child"
  for selector in . ..; do
    work_dir="$local_profile_dir"
    if [[ "$selector" == ".." ]]; then
      work_dir="$local_profile_dir/child"
    fi
    : >"$log_file"
    (
      cd "$work_dir"
      CAPSULE_PROFILES="$selector" DOCKER_GID=1111 \
        run_capsule "$mock_bin" "$log_file" true
    )
    assert_file_contains "$log_file" \
      "PROFILE_ENV_ENTRY=LOCAL_PROFILE='enabled'" \
      "$selector selects an explicit profile path"
  done
}

test_profile_names_fall_back_to_bundled_profiles() {
  local tdir="$TEST_TMPDIR/profile-bundled-name"
  local config_home="$tdir/config"
  local user_profile="$config_home/capsule/profiles/nvidia"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  XDG_CONFIG_HOME="$config_home" CAPSULE_PROFILES=nvidia \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
  assert_file_contains "$log_file" \
    "-f $ROOT_DIR/docker/compose-nvidia.yml" \
    "profile names fall back to profiles shipped with Capsule"

  mkdir -p "$user_profile"
  cat >"$user_profile/capsule.toml" <<'EOF'
version = 1
name = "nvidia"

[env]
USER_NVIDIA_PROFILE = "enabled"
EOF
  : >"$log_file"
  XDG_CONFIG_HOME="$config_home" CAPSULE_PROFILES=nvidia \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" true
  assert_file_contains "$log_file" \
    "PROFILE_ENV_ENTRY=USER_NVIDIA_PROFILE='enabled'" \
    "user profiles override same-named bundled profiles"
  assert_file_not_contains "$log_file" 'compose-nvidia.yml' \
    "overridden bundled profiles do not contribute settings"
}

test_duplicate_profile_directories_are_ignored() {
  local tdir="$TEST_TMPDIR/profile-duplicate"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local occurrence_count=""
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "duplicate-test"

[env]
DUPLICATE_PROFILE = "enabled"
EOF

  if CAPSULE_PROFILES="$profile_dir" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    --profile "$profile_dir/." true 2>"$err_file"; then
    pass "duplicate profile directories do not fail"
  else
    fail "duplicate profile directories do not fail"
  fi
  assert_file_contains "$err_file" \
    "ignoring duplicate profile directory: $profile_dir" \
    "duplicate profile directories emit a warning"
  occurrence_count="$(
    grep -Fo -- "PROFILE_ENV_ENTRY=DUPLICATE_PROFILE='enabled'" \
      "$log_file" | \
      wc -l | tr -d ' '
  )"
  assert_equals 1 "$occurrence_count" \
    "duplicate profile directories apply only once"
}

test_profile_volumes_use_host_path_map() {
  local tdir="$TEST_TMPDIR/profile-path-map"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "mapped-volume"
volume = [".:/profile"]
EOF

  CAPSULE_HOST_PATH_MAP="$profile_dir=/daemon/profile" \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --profile "$profile_dir" true

  assert_file_contains "$log_file" \
    '--volume /daemon/profile:/profile' \
    "profile volumes use CAPSULE_HOST_PATH_MAP"
}

test_nested_profile_home_volumes_use_host_visible_home() {
  local tdir="$TEST_TMPDIR/profile-nested-home"
  local home_dir="$tdir/home"
  local profile_dir="$home_dir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<EOF
version = 1
name = "nested-home"
volume = [
  "~:/profile-home",
  "~/.cache:/profile-cache",
  "$home_dir/absolute:/profile-absolute",
  "./relative:/profile-relative",
]
EOF

  HOME="$home_dir" DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/home/workspace/project" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    CAPSULE_HOME_HOST_DIR="/host/home/alice" \
    run_capsule "$mock_bin" "$log_file" \
    --profile "$profile_dir" true

  assert_file_contains "$log_file" \
    '--volume /host/home/alice:/profile-home' \
    "nested profile maps its home directory to the daemon host"
  assert_file_contains "$log_file" \
    '--volume /host/home/alice/.cache:/profile-cache' \
    "nested profile maps a tilde path to the daemon host"
  assert_file_contains "$log_file" \
    '--volume /host/home/alice/absolute:/profile-absolute' \
    "nested profile maps an absolute home path to the daemon host"
  assert_file_contains "$log_file" \
    '--volume /host/home/alice/profile/relative:/profile-relative' \
    "nested profile maps a relative home path to the daemon host"
}

test_nested_profile_home_volume_requires_host_visible_home() {
  local tdir="$TEST_TMPDIR/profile-nested-named-home"
  local home_dir="$tdir/home"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$home_dir" "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "nested-named-home"
volume = ["~/.cache:/profile-cache"]
EOF

  if HOME="$home_dir" DOCKER_GID=1111 \
    CAPSULE_WORKDIR="/home/workspace/project" \
    CAPSULE_HOST_WORKDIR="/host/workspace" \
    run_capsule "$mock_bin" "$log_file" \
    --profile "$profile_dir" true 2>"$err_file"; then
    fail "nested profile rejects an unmappable named-volume home"
  else
    pass "nested profile rejects an unmappable named-volume home"
  fi
  assert_file_contains "$err_file" \
    'inside Capsule requires CAPSULE_HOME_HOST_DIR' \
    "nested profile reports how to expose its home to the daemon"
}

test_profile_home_volume_uses_remote_home() {
  local tdir="$TEST_TMPDIR/profile-remote-home"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "remote-home"
volume = ["~/.cache/example:/cache"]
EOF

  CAPSULE_EXTRA_APPROVALS='ssh://builder/srv/project' \
    MOCK_SSH_OUTPUT=/home/remote DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/project --profile "$profile_dir" true

  assert_file_contains "$log_file" \
    '--volume /home/remote/.cache/example:/cache' \
    "profile home volumes resolve on a remote Docker host"
}

test_profile_home_volume_rejects_missing_remote_home() {
  local tdir="$TEST_TMPDIR/profile-missing-remote-home"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "remote-home"
volume = ["~/.cache/example:/cache"]
EOF

  if CAPSULE_EXTRA_APPROVALS='ssh://builder/srv/project' \
    MOCK_SSH_OUTPUT='' DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/project --profile "$profile_dir" true \
    2>"$err_file"; then
    fail "profile home volumes reject a missing remote home"
  else
    pass "profile home volumes reject a missing remote home"
  fi
  assert_file_contains "$err_file" \
    'failed to resolve remote home for profile volume' \
    "missing remote home reports a clear error"
}

test_remote_profile_volume_source_rules() {
  local tdir="$TEST_TMPDIR/profile-remote-volume-source"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  local local_source="$tdir/local-link/cache"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "remote-volume"
volume = ["./cache:/cache"]
EOF

  if CAPSULE_EXTRA_APPROVALS='ssh://builder/srv/project' \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/project --profile "$profile_dir" true \
    2>"$err_file"; then
    fail "remote profiles reject relative volume sources"
  else
    pass "remote profiles reject relative volume sources"
  fi
  assert_file_contains "$err_file" \
    'relative profile volume source is unsupported with --remote: ./cache' \
    "relative remote profile volume reports a clear error"

  : >"$log_file"
  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --remote builder --profile "$profile_dir" 2>"$err_file"; then
    pass "remote profile builds ignore relative runtime volumes"
  else
    fail "remote profile builds ignore relative runtime volumes"
  fi
  assert_file_not_contains "$log_file" ' run --rm ' \
    "remote profile builds do not start a container"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "remote-volume"
volume = ["/srv/cache:/cache"]
EOF

  CAPSULE_EXTRA_APPROVALS='ssh://builder/srv/project' \
    DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/project --profile "$profile_dir" true
  assert_file_contains "$log_file" '--volume /srv/cache:/cache' \
    "remote profiles accept absolute volume sources"

  mkdir -p "$tdir/local-target"
  ln -s "$tdir/local-target" "$tdir/local-link"
  cat >"$profile_dir/capsule.toml" <<EOF
version = 1
name = "remote-volume"
volume = ["$local_source:/cache"]
EOF

  : >"$log_file"
  CAPSULE_EXTRA_APPROVALS='ssh://builder/srv/project' \
    CAPSULE_HOST_PATH_MAP="$tdir=/daemon/client" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    --remote builder:/srv/project --profile "$profile_dir" true
  assert_file_contains "$log_file" \
    "--volume $local_source:/cache" \
    "remote profile volumes bypass local path translation"
}

test_profile_custom_build_generates_ordered_image() {
  local tdir="$TEST_TMPDIR/profile-build"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local token=""
  local generated_file=""
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  MOCK_CURL_FAIL=1 DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$PROFILE_CAPSULE_DIR"

  token="$(profile_path_token "$PROFILE_CAPSULE_DIR")"
  generated_file="$(profile_generated_file "$token" Dockerfile)"
  if [[ "${#token}" -eq 8 && "$token" != *[!0-9a-f]* ]]; then
    pass "profile image token is fixed-width lowercase hexadecimal"
  else
    fail "profile image token is fixed-width lowercase hexadecimal"
  fi
  assert_file_contains "$log_file" \
    "DOCKER_ARGS=build --tag casual-capsule-profile-test-profile-$token" \
    "profile custom build invokes Docker without release lookup"
  assert_file_contains "$log_file" \
    '--build-arg CAPSULE_BASE_IMAGE=casual-capsule-cli:latest' \
    "profile build extends the selected base image"
  assert_file_contains "$generated_file" \
    'ARG CAPSULE_BASE_IMAGE=casual-capsule-cli:latest' \
    "generated Dockerfile gives its base image argument a valid default"
  assert_file_contains "$log_file" \
    "--build-context test-profile=$PROFILE_CAPSULE_DIR" \
    "profile build supplies its directory as a named context"
  assert_file_contains "$generated_file" '# profile: test-profile' \
    "generated Dockerfile retains profile boundaries"
  assert_file_contains "$generated_file" 'ENV CUSTOM_CAPSULE_IMAGE=1' \
    "generated Dockerfile contains profile instructions"
}

test_generated_profile_files_are_cached_by_output() {
  local tdir="$TEST_TMPDIR/profile-generated-cache"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local token=""
  local cache_dir=""
  local artifact_dir=""
  local compose_file=""
  local first_artifact=""
  local second_artifact=""
  local artifact_count=""
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "generated-cache"
host = ["cache.internal=192.0.2.30"]

[dockerfile]
content = '''
ENV GENERATED_CACHE=1
'''
EOF

  CAPSULE_COMPOSE_PROJECT_NAME=first-project DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$tdir/first-log" \
    build --custom --profile "$profile_dir"
  CAPSULE_COMPOSE_PROJECT_NAME=second-project DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$tdir/second-log" \
    build --custom --profile "$profile_dir"

  token="$(profile_path_token "$profile_dir")"
  cache_dir="$PROFILE_CACHE_DIR/$token"
  for compose_file in "$cache_dir"/*/compose.yml; do
    [[ -f "$compose_file" ]] || continue
    artifact_dir="${compose_file%/compose.yml}"
    if grep -Fq 'image: first-project-profile-generated-cache-' \
      "$compose_file"; then
      first_artifact="$artifact_dir"
    elif grep -Fq 'image: second-project-profile-generated-cache-' \
      "$compose_file"; then
      second_artifact="$artifact_dir"
    fi
    assert_file_contains "$artifact_dir/.complete" '1' \
      "generated profile artifact is marked complete"
  done
  artifact_count="$(
    find "$cache_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | \
      tr -d ' '
  )"
  assert_equals 2 "$artifact_count" \
    "project-specific generated files use distinct cache entries"
  if [[ -z "$first_artifact" || -z "$second_artifact" ]]; then
    fail "a project loses its generated Compose override"
    return
  elif [[ "$first_artifact" == "$second_artifact" ]]; then
    fail "project-specific generated Compose overrides collide"
    return
  else
    pass "both projects retain distinct generated Compose overrides"
  fi

  printf '%s\n' 'reuse-sentinel' >"$first_artifact/.complete"
  CAPSULE_COMPOSE_PROJECT_NAME=first-project DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$tdir/reuse-log" \
    build --custom --profile "$profile_dir"
  assert_file_contains "$first_artifact/.complete" 'reuse-sentinel' \
    "complete generated profile artifacts are reused without rendering"
  if find "$cache_dir" -type f \
    \( -name '.Dockerfile.*' -o -name '.compose.yml.*' \
    -o -name '.complete.*' \) | grep -q .; then
    fail "generated profile cache retains temporary files"
  else
    pass "generated profile cache publishes without temporary leftovers"
  fi
}


test_profile_build_preserves_selected_order() {
  local tdir="$TEST_TMPDIR/profile-order"
  local first_dir="$tdir/first"
  local second_dir="$tdir/second"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local forward_token=""
  local reverse_token=""
  local generated_file=""
  mkdir -p "$first_dir" "$second_dir"
  make_mock_bin "$mock_bin"

  cat >"$first_dir/capsule.toml" <<'EOF'
version = 1
name = "first"

[dockerfile]
content = '''
ENV PROFILE_ORDER=first
'''
EOF
  cat >"$second_dir/capsule.toml" <<'EOF'
version = 1
name = "second"

[dockerfile]
content = '''
ENV PROFILE_ORDER=second
'''
EOF

  CAPSULE_PROFILES="$first_dir;$second_dir" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" build --custom
  forward_token="$(profile_path_token "$first_dir" "$second_dir")"
  generated_file="$(profile_generated_file "$forward_token" Dockerfile)"
  assert_file_contains "$log_file" \
    "--tag casual-capsule-profile-first-second-$forward_token:local" \
    "profile image names preserve selected profile order"
  assert_file_contains \
    "$generated_file" \
    $'# profile: first\nENV PROFILE_ORDER=first\n\n# profile: second' \
    "profile fragments retain command-line order"

  : >"$log_file"
  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$second_dir" --profile "$first_dir"
  reverse_token="$(profile_path_token "$second_dir" "$first_dir")"
  generated_file="$(profile_generated_file "$reverse_token" Dockerfile)"
  assert_file_contains "$log_file" \
    "--tag casual-capsule-profile-second-first-$reverse_token:local" \
    "reversed profile names remain readable in the image tag"
  if [[ "$forward_token" != "$reverse_token" ]]; then
    pass "reversing profiles selects a distinct image tag"
  else
    fail "reversing profiles selects a distinct image tag"
  fi
  assert_file_contains \
    "$generated_file" \
    $'# profile: second\nENV PROFILE_ORDER=second\n\n# profile: first' \
    "reversing profiles reverses generated instructions"
}

test_profile_accepts_multiline_eof_without_newline() {
  local tdir="$TEST_TMPDIR/profile-multiline-eof"
  local array_dir="$tdir/array"
  local profile_dir="$tdir/dockerfile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local token=""
  local generated_file=""
  mkdir -p "$array_dir/data" "$profile_dir"
  make_mock_bin "$mock_bin"

  printf '%s' 'version = 1
name = "array-eof"
volume = [
  "./data:/data",
]' >"$array_dir/capsule.toml"
  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --profile "$array_dir" true
  assert_file_contains "$log_file" \
    "--volume $array_dir/data:/data" \
    "multiline arrays accept an unterminated final line"

  printf '%s' "version = 1
name = \"dockerfile-eof\"

[dockerfile]
content = '''
ENV PROFILE_EOF=1
'''" >"$profile_dir/capsule.toml"
  DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$profile_dir"
  token="$(profile_path_token "$profile_dir")"
  generated_file="$(profile_generated_file "$token" Dockerfile)"
  assert_file_contains "$generated_file" 'ENV PROFILE_EOF=1' \
    "Dockerfile content accepts an unterminated final line"
}

test_profile_rejects_unsupported_toml() {
  local tdir="$TEST_TMPDIR/profile-invalid"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "invalid"
volume = { source = "/tmp", target = "/tmp" }
EOF
  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$profile_dir" 2>"$err_file"; then
    fail "profiles reject unsupported valid TOML"
  else
    pass "profiles reject unsupported valid TOML"
  fi
  assert_file_contains "$err_file" 'invalid or unsupported string array' \
    "unsupported TOML reports a profile parser error"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "invalid"

[env]
BROKEN = "prefix-${SOURCE_VALUE}"
EOF
  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$profile_dir" 2>"$err_file"; then
    fail "profiles reject partial interpolation"
  else
    pass "profiles reject partial interpolation"
  fi
  assert_file_contains "$err_file" 'invalid partial interpolation' \
    "partial interpolation reports a clear error"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "invalid"

[dockerfile]
content = '''
FROM alpine:3.20
'''
EOF
  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    build --custom --profile "$profile_dir" 2>"$err_file"; then
    fail "profiles reject Dockerfile FROM instructions"
  else
    pass "profiles reject Dockerfile FROM instructions"
  fi
  assert_file_contains "$err_file" \
    'Dockerfile content must not contain FROM' \
    "a forbidden FROM instruction reports a clear error"
}

test_profiles_conflict_with_custom_compose() {
  local tdir="$TEST_TMPDIR/profile-compose-conflict"
  local custom_dir="$tdir/custom"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"
  make_custom_compose "$custom_dir" "legacy:local"

  if CAPSULE_CUSTOM_COMPOSE="$custom_dir/compose.yml" DOCKER_GID=1111 \
    run_capsule "$mock_bin" "$log_file" \
    --profile "$PROFILE_CAPSULE_DIR" true 2>"$err_file"; then
    fail "profiles conflict with legacy custom Compose"
  else
    pass "profiles conflict with legacy custom Compose"
  fi
  assert_file_contains "$err_file" \
    'profiles cannot be combined with CAPSULE_CUSTOM_COMPOSE' \
    "profile and custom Compose conflict reports a clear error"
}

test_profile_option_rejects_empty_selector() {
  local tdir="$TEST_TMPDIR/profile-empty-option"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  local err_file="$tdir/err"
  mkdir -p "$tdir"
  make_mock_bin "$mock_bin"

  if DOCKER_GID=1111 run_capsule "$mock_bin" "$log_file" \
    --profile= true 2>"$err_file"; then
    fail "an empty --profile value is rejected"
  else
    pass "an empty --profile value is rejected"
  fi
  assert_file_contains "$err_file" \
    '--profile requires a name or directory path' \
    "empty profile option reports a clear error"
}

test_podman_profile_runtime_settings() {
  local tdir="$TEST_TMPDIR/podman-profile"
  local profile_dir="$tdir/profile"
  local workspace="$tdir/workspace"
  local mock_bin="$tdir/bin"
  local log_file="$tdir/log"
  mkdir -p "$profile_dir" "$workspace"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "podman-runtime"
gpu = "all"
namespace = "gpu"
host = ["gpu.internal=192.0.2.20"]

[env]
PROFILE_FLAG = "enabled"
EOF

  CAPSULE_WORKDIR="$workspace" \
    run_capsule "$mock_bin" "$log_file" --runtime podman \
    --profile "$profile_dir" true

  assert_podman_args_contain "$log_file" \
    '--device nvidia.com/gpu=all' \
    "podman profile requests all NVIDIA devices"
  assert_podman_args_lack "$log_file" '--env PROFILE_FLAG=enabled' \
    "podman profile keeps environment values out of arguments"
  assert_podman_args_contain "$log_file" '--env-file ' \
    "podman reads profile environment from a private file"
  assert_file_contains "$log_file" \
    'PROFILE_ENV_ENTRY=PROFILE_FLAG=enabled' \
    "podman profile forwards environment values"
  assert_file_contains "$log_file" 'PROFILE_ENV_PERMISSIONS=600' \
    "podman profile environment file is owner-readable only"
  profile_env_file="$(value_from_log PROFILE_ENV_FILE "$log_file")"
  if [[ -n "$profile_env_file" && ! -e "$profile_env_file" ]]; then
    pass "profile environment file is removed after podman exits"
  else
    fail "profile environment file remains after podman exits"
  fi
  assert_podman_args_contain "$log_file" \
    '--add-host gpu.internal:192.0.2.20' \
    "podman profile forwards static host mappings"
  assert_podman_args_contain "$log_file" \
    '--volume casual-capsule-home-gpu:/home/user' \
    "podman profile namespaces persistent home state"
  assert_podman_args_contain "$log_file" 'capsule-workspace-gpu-' \
    "podman profile namespaces generated container names"
}

test_podman_profile_image_includes_base_identity() {
  local tdir="$TEST_TMPDIR/podman-profile-base"
  local profile_dir="$tdir/profile"
  local mock_bin="$tdir/bin"
  local path_token=""
  local first_base_token=""
  local second_base_token=""
  local first_image=""
  local second_image=""
  mkdir -p "$profile_dir"
  make_mock_bin "$mock_bin"

  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "podman-base"

[dockerfile]
content = '''
ENV PODMAN_BASE_PROFILE=1
'''
EOF

  path_token="$(profile_path_token "$profile_dir")"
  first_base_token="$(
    printf '%s\0' 'base-a:local' | cksum | cut -d' ' -f1
  )"
  printf -v first_base_token '%08x' "$first_base_token"
  second_base_token="$(
    printf '%s\0' 'base-b:local' | cksum | cut -d' ' -f1
  )"
  printf -v second_base_token '%08x' "$second_base_token"
  first_image="casual-capsule-profile-podman-base-${path_token}"
  first_image="${first_image}-${first_base_token}:local"
  second_image="casual-capsule-profile-podman-base-${path_token}"
  second_image="${second_image}-${second_base_token}:local"

  CAPSULE_RUNTIME=podman CAPSULE_IMAGE=base-a:local \
    run_capsule "$mock_bin" "$tdir/first-log" \
    build --custom --profile "$profile_dir"
  CAPSULE_RUNTIME=podman CAPSULE_IMAGE=base-b:local \
    run_capsule "$mock_bin" "$tdir/second-log" \
    build --custom --profile "$profile_dir"

  assert_podman_args_contain "$tdir/first-log" "--tag $first_image" \
    "first Podman base selects its own profile image"
  assert_podman_args_contain "$tdir/first-log" \
    '--build-arg CAPSULE_BASE_IMAGE=base-a:local' \
    "first Podman profile image extends its selected base"
  assert_podman_args_contain "$tdir/second-log" "--tag $second_image" \
    "second Podman base selects a distinct profile image"
  assert_podman_args_contain "$tdir/second-log" \
    '--build-arg CAPSULE_BASE_IMAGE=base-b:local' \
    "second Podman profile image extends its selected base"
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
  assert_podman_args_lack "$CASE_LOG" 'CAPSULE_RUNTIME=' \
    "podman backend leaves nested backend selection automatic"
  assert_podman_args_contain "$CASE_LOG" \
    '--env CAPSULE_UID=1000' \
    "podman backend records the host UID for Capsule queries"
  assert_podman_args_contain "$CASE_LOG" \
    'casual-capsule:local claude' \
    "podman backend passes the command after the image"
}

test_podman_preserves_piped_stdin() {
  setup_mock_case podman-stdin

  printf 'capsule piped payload\n' |
    CAPSULE_RUNTIME=podman MOCK_PODMAN_STDIN_FILE="$CASE_DIR/stdin" \
    run_capsule "$CASE_BIN" "$CASE_LOG" cat >"$CASE_DIR/out"

  assert_podman_args_contain "$CASE_LOG" '--interactive' \
    "Podman keeps stdin open for non-TTY commands"
  assert_podman_args_lack "$CASE_LOG" '--tty' \
    "Podman does not allocate a TTY for piped input"
  assert_file_contains "$CASE_DIR/stdin" 'capsule piped payload' \
    "piped input reaches Podman without approval or setup consuming it"
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
  mkdir -p "$CASE_DIR/run"

  XDG_RUNTIME_DIR="$CASE_DIR/run" MOCK_UNAME=Linux \
    CAPSULE_RUNTIME=podman GITHUB_API_TOKEN=token-value \
    run_capsule "$CASE_BIN" "$CASE_LOG" true

  assert_podman_args_contain "$CASE_LOG" \
    "$CASE_DIR/run/capsule/github_api_token." \
    "podman secrets use XDG_RUNTIME_DIR on Linux"
  assert_podman_args_contain "$CASE_LOG" \
    ':/run/secrets/github_api_token:ro' \
    "podman backend mounts the token where the entrypoint reads it"
  assert_podman_args_lack "$CASE_LOG" \
    'token-value' \
    "podman backend passes the token as a file, never on a command line"

  : >"$CASE_LOG"
  XDG_RUNTIME_DIR='' XDG_CACHE_HOME="$CASE_DIR/cache" \
    MOCK_UNAME=Linux CAPSULE_RUNTIME=podman \
    GITHUB_API_TOKEN=token-value \
    run_capsule "$CASE_BIN" "$CASE_LOG" true
  assert_podman_args_contain "$CASE_LOG" \
    "$CASE_DIR/cache/capsule/runtime/github_api_token." \
    "podman secrets use XDG cache without a runtime directory"

  : >"$CASE_LOG"
  mkdir -p "$CASE_DIR/home/project"
  HOME="$CASE_DIR/home" XDG_CACHE_HOME="$CASE_DIR/outside-cache" \
    CAPSULE_WORKDIR="$CASE_DIR/home/project" MOCK_UNAME=Darwin \
    CAPSULE_RUNTIME=podman \
    GITHUB_API_TOKEN=token-value \
    run_capsule "$CASE_BIN" "$CASE_LOG" true
  assert_podman_args_contain "$CASE_LOG" \
    "$CASE_DIR/home/.cache/capsule/runtime/github_api_token." \
    "macOS podman secrets remain under the shared home"
  assert_podman_args_lack "$CASE_LOG" "$CASE_DIR/outside-cache" \
    "macOS podman secrets ignore cache paths outside the shared home"
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

  CAPSULE_RUNTIME=podman CAPSULE_REQUIRE_HOST_DOCKER=1 \
    DOCKER_HOST="unix://$socket_path" \
    run_capsule "$CASE_BIN" "$CASE_DIR/nested" true
  assert_podman_args_lack "$CASE_DIR/nested" '/var/lib/capsule/docker.sock' \
    "an outer Capsule's socket requirement does not expose it to children"
  assert_podman_args_lack "$CASE_DIR/nested" 'CAPSULE_REQUIRE_HOST_DOCKER' \
    "an isolated child does not inherit the outer socket requirement"

  CAPSULE_RUNTIME=podman DOCKER_HOST="unix://$socket_path" \
    run_capsule "$CASE_BIN" "$CASE_DIR/with" --host-docker true
  assert_podman_args_contain "$CASE_DIR/with" \
    "${socket_path}:/var/lib/capsule/docker.sock" \
    "--host-docker binds the host daemon socket deliberately"
  assert_podman_args_contain "$CASE_DIR/with" '--group-add keep-groups' \
    "--host-docker preserves supplementary socket groups"
  assert_podman_args_contain "$CASE_DIR/with" \
    '--env CAPSULE_REQUIRE_HOST_DOCKER=1' \
    "--host-docker requires the selected socket inside the Capsule"

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

  CAPSULE_RUNTIME=auto MOCK_PODMAN_INFO="false crun" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'podman is running rootful' \
    "a rootful podman falls back rather than run the Capsule as root"
  assert_file_contains "$CASE_LOG" \
    'compose' \
    "the fallback actually runs the Docker backend"
}

test_explicit_podman_does_not_fall_back() {
  local selection=""
  setup_mock_case podman-explicit-failure

  for selection in env flag; do
    : >"$CASE_LOG"
    if [[ "$selection" == "env" ]]; then
      if CAPSULE_RUNTIME=podman MOCK_PODMAN_INFO_FAIL=1 \
        run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"; then
        fail "explicit Podman environment refuses fallback"
      else
        pass "explicit Podman environment refuses fallback"
      fi
    elif CAPSULE_RUNTIME=auto MOCK_PODMAN_INFO_FAIL=1 \
      run_capsule "$CASE_BIN" "$CASE_LOG" --runtime podman true \
      2>"$CASE_ERR"; then
      fail "explicit Podman flag refuses fallback"
    else
      pass "explicit Podman flag refuses fallback"
    fi
    assert_file_contains "$CASE_ERR" 'cannot use podman' \
      "explicit $selection selection explains why Podman cannot run"
    assert_file_not_contains "$CASE_LOG" 'compose' \
      "explicit $selection selection never exposes host Docker"
  done
}

test_podman_checks_uid_and_gid_capacity() {
  local count=""
  setup_mock_case podman-id-capacity

  for count in 1 32769 65536; do
    : >"$CASE_LOG"
    CAPSULE_RUNTIME=auto MOCK_PODMAN_GID_COUNT="$count" \
      run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"
    assert_file_contains "$CASE_ERR" 'insufficient subordinate GIDs' \
      "Podman rejects a GID allocation of $count total IDs"
    assert_file_contains "$CASE_LOG" 'compose' \
      "auto uses Docker when GID capacity is $count"
  done

  if CAPSULE_RUNTIME=podman MOCK_PODMAN_UID_COUNT=65536 \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"; then
    fail "explicit Podman rejects an undersized UID allocation"
  else
    pass "explicit Podman rejects an undersized UID allocation"
  fi
  assert_file_contains "$CASE_ERR" 'insufficient subordinate UIDs' \
    "the UID allocation error names the missing capacity"

  CAPSULE_RUNTIME=podman \
    MOCK_PODMAN_UID_COUNT=$'1\nuid 32768\nuid 32768' \
    MOCK_PODMAN_GID_COUNT=$'1\ngid 32768\ngid 32768' \
    run_capsule "$CASE_BIN" "$CASE_DIR/fragmented" true
  assert_podman_args_contain "$CASE_DIR/fragmented" 'run --rm' \
    "Podman accepts sufficient capacity across multiple ID ranges"
}

test_doctor_checks_gid_capacity() {
  local tdir="$TEST_TMPDIR/doctor-gids"
  mkdir -p "$tdir"
  make_doctor_bin "$tdir/bin"

  if MOCK_PODMAN_GID_COUNT=1 PATH="$tdir/bin" \
    "$DOCTOR_PATH" >"$tdir/out" 2>&1; then
    fail "doctor rejects missing subordinate GIDs"
  else
    pass "doctor rejects missing subordinate GIDs"
  fi
  assert_file_contains "$tdir/out" 'insufficient subordinate GIDs' \
    "doctor diagnoses a GID-only mapping failure"
}

test_github_token_is_optional() {
  local compose_file=""
  local profile_dir=""
  setup_mock_case optional-github-token
  compose_file="$CASE_DIR/custom.yml"
  profile_dir="$CASE_DIR/profile"
  mkdir -p "$profile_dir"
  printf 'services:\n  cli:\n    image: custom:latest\n' >"$compose_file"
  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "optional-token"

[dockerfile]
content = '''
ENV OPTIONAL_TOKEN_PROFILE=1
'''
EOF

  unset GITHUB_API_TOKEN
  CAPSULE_PROFILES="$profile_dir" CAPSULE_RUNTIME=docker \
    run_capsule "$CASE_BIN" "$CASE_LOG" --build true
  assert_file_not_contains "$CASE_LOG" 'compose.github-token.yml' \
    "Docker builds and runs without a token override"
  assert_file_not_contains "$CASE_LOG" \
    '--secret id=github_api_token,env=GITHUB_API_TOKEN' \
    "Docker profile builds without a GitHub secret"

  GITHUB_API_TOKEN=token-value CAPSULE_RUNTIME=docker \
    run_capsule "$CASE_BIN" "$CASE_DIR/docker-token" --build true
  assert_file_contains "$CASE_DIR/docker-token" \
    "-f $TOKEN_COMPOSE_PATH" \
    "Docker adds the token secret override when supplied"
  assert_file_not_contains "$CASE_DIR/docker-token" 'token-value' \
    "Docker keeps the token off its command line"

  GITHUB_API_TOKEN=token-value CAPSULE_RUNTIME=docker \
    CAPSULE_CUSTOM_COMPOSE="$compose_file" \
    run_capsule "$CASE_BIN" "$CASE_DIR/custom-token" --build true
  assert_file_contains "$CASE_DIR/custom-token" \
    "-f $TOKEN_COMPOSE_PATH -f $compose_file" \
    "custom Compose builds and runs retain the supplied token override"

  GITHUB_API_TOKEN='' CAPSULE_PROFILES="$profile_dir" \
    CAPSULE_RUNTIME=podman \
    run_capsule "$CASE_BIN" "$CASE_DIR/podman" --build true
  assert_podman_args_lack "$CASE_DIR/podman" '--secret' \
    "Podman builds without a GitHub secret"
  assert_podman_args_lack "$CASE_DIR/podman" '/run/secrets/github_api_token' \
    "Podman runs without a GitHub secret mount"

  make_doctor_bin "$CASE_DIR/doctor-bin"
  GITHUB_API_TOKEN='' PATH="$CASE_DIR/doctor-bin" \
    "$DOCTOR_PATH" >"$CASE_DIR/doctor" 2>&1 || true
  assert_file_contains "$CASE_DIR/doctor" 'GITHUB_API_TOKEN is optional' \
    "doctor explains tokenless operation"
}

test_host_docker_requires_group_support() {
  setup_mock_case podman-hostdocker-groups
  : >"$CASE_DIR/docker.sock"

  if CAPSULE_RUNTIME=podman MOCK_PODMAN_RUNTIME=runc \
    DOCKER_HOST="unix://$CASE_DIR/docker.sock" \
    run_capsule "$CASE_BIN" "$CASE_LOG" --host-docker true \
    2>"$CASE_ERR"; then
    fail "host Docker refuses a runtime that cannot preserve groups"
  else
    pass "host Docker refuses a runtime that cannot preserve groups"
  fi
  assert_file_contains "$CASE_ERR" '--host-docker requires crun' \
    "host Docker explains how to retain socket group access"
}

test_podman_falls_back_without_a_subid_range() {
  setup_mock_case podman-nosubid

  CAPSULE_RUNTIME=auto MOCK_PODMAN_UID_COUNT=1 \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'insufficient subordinate UIDs' \
    "a user with no sub-id range falls back and names the package"
}

test_podman_falls_back_when_engine_unreachable() {
  setup_mock_case podman-unreachable

  CAPSULE_RUNTIME=auto MOCK_PODMAN_INFO_FAIL=1 \
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
    CAPSULE_RUNTIME=auto MOCK_SSH_OUTPUT=1234 \
    run_capsule "$CASE_BIN" "$CASE_LOG" \
    --remote remote-host:/srv/project true 2>"$CASE_ERR"
  assert_file_contains "$CASE_ERR" \
    '--remote needs a Docker daemon' \
    "--remote falls back to Docker with the reason named"

  CAPSULE_RUNTIME=auto CAPSULE_CUSTOM_COMPOSE="$compose_file" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"
  assert_file_contains "$CASE_ERR" \
    'custom compose file needs the Docker backend' \
    "a compose override falls back to Docker with the reason named"
}

test_podman_on_macos_requires_workspace_under_home() {
  setup_mock_case podman-macos
  mkdir -p "$CASE_DIR/home" "$CASE_DIR/elsewhere"

  CAPSULE_RUNTIME=auto MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
    CAPSULE_WORKDIR="$CASE_DIR/elsewhere" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'podman machine cannot see it' \
    "a workspace the podman machine cannot see falls back to Docker"
}

test_podman_on_macos_requires_profiles_under_home() {
  local profile_dir=""
  setup_mock_case podman-macos-profile
  profile_dir="$CASE_DIR/profile"
  mkdir -p "$CASE_DIR/home/project" "$profile_dir"
  cat >"$profile_dir/capsule.toml" <<'EOF'
version = 1
name = "outside-home"
EOF

  CAPSULE_RUNTIME=auto MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
    CAPSULE_WORKDIR="$CASE_DIR/home/project" \
    run_capsule "$CASE_BIN" "$CASE_LOG" \
    --profile "$profile_dir" true 2>"$CASE_ERR"

  assert_file_contains "$CASE_ERR" \
    'a profile directory is outside' \
    "a profile the podman machine cannot see falls back to Docker"
}

test_podman_on_macos_requires_profile_volumes_under_home() {
  local profile_dir=""
  local source=""
  setup_mock_case podman-macos-profile-volume
  profile_dir="$CASE_DIR/home/profile"
  mkdir -p "$CASE_DIR/home/project" "$profile_dir" \
    "$CASE_DIR/elsewhere"

  for source in \
    "$CASE_DIR/elsewhere/absolute" \
    '../../elsewhere/relative'; do
    cat >"$profile_dir/capsule.toml" <<EOF
version = 1
name = "outside-home-volume"
volume = ["$source:/data"]
EOF
    : >"$CASE_LOG"
    : >"$CASE_ERR"

    CAPSULE_RUNTIME=auto MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
      CAPSULE_WORKDIR="$CASE_DIR/home/project" \
      run_capsule "$CASE_BIN" "$CASE_LOG" \
      --profile "$profile_dir" true 2>"$CASE_ERR"

    assert_file_contains "$CASE_ERR" \
      'a profile volume source is outside' \
      "an inaccessible profile volume makes Podman fall back"
    assert_file_contains "$CASE_LOG" 'compose' \
      "Docker runs when Podman cannot see a profile volume"
  done

  : >"$CASE_LOG"
  : >"$CASE_ERR"
  CAPSULE_RUNTIME=podman MOCK_UNAME=Darwin HOME="$CASE_DIR/home" \
    CAPSULE_WORKDIR="$CASE_DIR/home/project" \
    run_capsule "$CASE_BIN" "$CASE_LOG" build \
    --profile "$profile_dir" 2>"$CASE_ERR"

  assert_podman_args_contain "$CASE_LOG" 'build ' \
    "podman profile builds ignore inaccessible runtime volumes"
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
  for tool in bash basename cat chmod mkdir rm sleep; do
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
original_args="$*"
config="${DOCKER_CONFIG:-}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --config=*) config="${1#--config=}"; shift ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then
  if [[ -n "$config" && -f "$config/current-context" ]]; then
    cat "$config/current-context"
  else
    printf '%s\n' "${MOCK_ROUTER_CONTEXT:-default}"
  fi
  exit 0
fi
socket="${DOCKER_HOST:-}"
socket="${socket#unix://}"
if [[ "${1:-}" == "version" ]]; then
  [[ -e "$socket" ]] || exit 1
  [[ "$socket" != "${ROUTER_BROKEN_SOCKET:-}" ]] || exit 1
  exit 0
fi
printf 'ROUTED=%s ARGS=%s\n' "$socket" "$original_args" >>"${ROUTER_LOG:?}"
printf 'CLIENT_HOST=%s CLIENT_CONTEXT=%s\n' \
  "${DOCKER_HOST:-}" "${DOCKER_CONTEXT:-}" >>"$ROUTER_LOG"
EOF

  # Record shutdown requests; cleanup below only matches fixture paths.
  cat >"$dir/bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf 'STOP_REQUEST=%s\n' "$*" >>"${ROUTER_LOG:?}"
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
printf 'DOCKERD_ARGS=%s\n' "$*" >>"${ROUTER_LOG:?}"
sleep 5
EOF
    chmod +x "$dir/bin/dockerd-rootless.sh"
  fi

  chmod +x "$dir/bin/podman" "$dir/bin/pkill" "$dir/real/docker"
}

# Run the router under one of its two names.
run_router() {
  local dir="$1"
  local invoked_as="$2"
  shift 2

  if [[ "$invoked_as" == "docker" ]]; then
    PATH="$dir/bin" CAPSULE_ENGINE_DIR="$dir/state" \
      CAPSULE_INNER_DIR="$dir/inner" \
      CAPSULE_REAL_DOCKER="$dir/real/docker" \
      CAPSULE_HOST_SOCKET="$dir/hostsock" \
      ROUTER_LOG="$dir/routed" \
      "$dir/bin/docker" "$@"
    return
  fi

  PATH="$dir/bin" CAPSULE_ENGINE_DIR="$dir/state" \
    CAPSULE_INNER_DIR="$dir/inner" \
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
  assert_file_contains "$dir/routed" "--data-root=$dir/inner/docker" \
    "dockerd stores persistent state in the workspace engine volume"
  assert_file_contains "$dir/routed" "--exec-root=$dir/state/docker-exec" \
    "dockerd keeps execution state private to this Capsule"
  assert_file_contains "$dir/routed" "--pidfile=$dir/state/docker.pid" \
    "dockerd keeps its PID file private to this Capsule"

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

test_router_preserves_explicit_endpoints() {
  local dir="$TEST_TMPDIR/router-endpoints"
  local endpoint=""
  local selection=""
  local options=()
  make_router_env "$dir"
  : >"$dir/hostsock"

  for endpoint in ssh://buildbox tcp://builder:2376 unix:///custom.sock; do
    : >"$dir/routed"
    DOCKER_HOST="$endpoint" CAPSULE_REQUIRE_HOST_DOCKER=1 \
      run_router "$dir" docker compose ps
    assert_file_contains "$dir/routed" "CLIENT_HOST=$endpoint " \
      "the router preserves the explicit $endpoint endpoint"
  done

  : >"$dir/routed"
  DOCKER_CONTEXT=remote-builder DOCKER_HOST="unix://$dir/hostsock" \
    run_router "$dir" docker ps
  assert_file_contains "$dir/routed" 'CLIENT_CONTEXT=remote-builder' \
    "the router preserves an explicit context over the image endpoint"

  for selection in host short-host joined-host context short-context; do
    case "$selection" in
      host) options=(--host ssh://buildbox) ;;
      short-host) options=(-H ssh://buildbox) ;;
      joined-host) options=(-Hssh://buildbox) ;;
      context) options=(--context=remote-builder) ;;
      short-context) options=(-c remote-builder) ;;
    esac
    : >"$dir/routed"
    run_router "$dir" docker --config "$dir/config" \
      "${options[@]}" compose ps
    assert_file_contains "$dir/routed" 'CLIENT_HOST= CLIENT_CONTEXT=' \
      "the router leaves native endpoint selection to $selection flags"
    assert_file_contains "$dir/routed" "${options[*]} compose ps" \
      "the router forwards $selection arguments unchanged"
  done

  : >"$dir/routed"
  MOCK_ROUTER_CONTEXT=remote-builder run_router "$dir" docker ps
  assert_file_contains "$dir/routed" 'CLIENT_HOST= CLIENT_CONTEXT=' \
    "the router respects a non-default active Docker context"

  : >"$dir/routed"
  run_router "$dir" docker run alpine echo --host ssh://buildbox
  assert_file_contains "$dir/routed" "CLIENT_HOST=unix://$dir/hostsock " \
    "a container command argument is not treated as a Docker endpoint flag"

  : >"$dir/routed"
  DOCKER_HOST="unix://$dir/hostsock" run_router "$dir" docker ps
  assert_file_contains "$dir/routed" "ROUTED=$dir/hostsock ARGS=ps" \
    "the image's default endpoint still uses Capsule routing"
  stop_router_env "$dir"
}

test_nested_remote_commands_use_router() {
  local command=""
  setup_mock_case nested-remote-router
  mv "$CASE_BIN/docker" "$CASE_BIN/docker-real"
  ln -s "$ROUTER_PATH" "$CASE_BIN/docker"

  for command in run build list; do
    : >"$CASE_LOG"
    if [[ "$command" == "list" ]]; then
      CAPSULE_REAL_DOCKER="$CASE_BIN/docker-real" \
        run_capsule "$CASE_BIN" "$CASE_LOG" list --remote buildbox \
        >"$CASE_DIR/list-out"
      assert_file_contains "$CASE_LOG" 'DOCKER_PS_HOST=ssh://buildbox' \
        "nested remote listing reaches the requested endpoint through router"
    else
      CAPSULE_REAL_DOCKER="$CASE_BIN/docker-real" MOCK_SSH_OUTPUT=1234 \
        CAPSULE_EXTRA_APPROVALS=ssh://buildbox/srv/project \
        run_capsule "$CASE_BIN" "$CASE_LOG" \
        "$command" --remote buildbox:/srv/project
      assert_file_contains "$CASE_LOG" 'ENV_DOCKER_HOST=ssh://buildbox' \
        "nested remote $command reaches the requested endpoint through router"
    fi
  done
}

test_nested_commands_use_generated_podman_environment() {
  local assignment=""
  local command=""
  local selection=""
  local runtime=""
  local child_env=()
  local options=()
  setup_mock_case nested-generated-env

  CAPSULE_RUNTIME=auto MOCK_PODMAN_ENV_FILE="$CASE_DIR/child-env" \
    run_capsule "$CASE_BIN" "$CASE_LOG" true
  assert_file_not_contains "$CASE_DIR/child-env" 'CAPSULE_RUNTIME=' \
    "an automatically selected Podman capsule does not force its children"
  while IFS= read -r assignment; do
    child_env+=("$assignment")
  done <"$CASE_DIR/child-env"
  printf '%s\n' "$(pwd -P)" 'ssh://buildbox/srv/project' >"$CASE_DIR/config"

  for command in run build; do
    options=("$command" --remote buildbox:/srv/project)
    [[ "$command" != "run" ]] || options+=(true)
    : >"$CASE_LOG"
    env -u CAPSULE_RUNTIME "${child_env[@]}" PATH="$CASE_BIN:$PATH" \
      MOCK_LOG="$CASE_LOG" MOCK_SSH_OUTPUT=1234 \
      CAPSULE_CONFIG="$CASE_DIR/config" \
      "$SCRIPT_PATH" "${options[@]}" 2>"$CASE_ERR"
    assert_file_contains "$CASE_LOG" 'ENV_DOCKER_HOST=ssh://buildbox' \
      "a real generated Podman environment permits nested remote $command"
  done

  printf 'services:\n  cli:\n    image: custom:latest\n' >"$CASE_DIR/custom.yml"
  for command in run build; do
    options=("$command")
    if [[ "$command" == "build" ]]; then
      options+=(--custom)
    else
      options+=(true)
    fi
    : >"$CASE_LOG"
    env -u CAPSULE_RUNTIME "${child_env[@]}" PATH="$CASE_BIN:$PATH" \
      MOCK_LOG="$CASE_LOG" CAPSULE_CONFIG="$CASE_DIR/config" \
      CAPSULE_CUSTOM_COMPOSE="$CASE_DIR/custom.yml" \
      "$SCRIPT_PATH" "${options[@]}" 2>"$CASE_ERR"
    assert_file_contains "$CASE_LOG" "-f $CASE_DIR/custom.yml" \
      "a real generated Podman environment permits nested custom $command"
  done

  for selection in env flag; do
    options=(build --remote buildbox:/srv/project)
    runtime=auto
    if [[ "$selection" == "env" ]]; then
      runtime=podman
    else
      options+=(--runtime podman)
    fi
    if env "${child_env[@]}" CAPSULE_RUNTIME="$runtime" PATH="$CASE_BIN:$PATH" \
      MOCK_LOG="$CASE_LOG" "$SCRIPT_PATH" "${options[@]}" \
      2>"$CASE_ERR"; then
      fail "an explicit nested Podman $selection selection still fails closed"
    else
      pass "an explicit nested Podman $selection selection still fails closed"
    fi
  done
}

test_router_honors_alternate_config() {
  local dir="$TEST_TMPDIR/router-config"
  local context=""
  local ordinary_context=""
  local syntax=""
  local options=()
  make_router_env "$dir"
  mkdir -p "$dir/alternate config"
  : >"$dir/hostsock"

  for context in default remote-builder; do
    ordinary_context=default
    if [[ "$context" == "default" ]]; then
      ordinary_context=remote-ordinary
    fi
    printf '%s\n' "$context" >"$dir/alternate config/current-context"
    for syntax in split joined; do
      if [[ "$syntax" == "split" ]]; then
        options=(--config "$dir/alternate config")
      else
        options=("--config=$dir/alternate config")
      fi
      : >"$dir/routed"
      MOCK_ROUTER_CONTEXT="$ordinary_context" \
        run_router "$dir" docker "${options[@]}" ps
      if [[ "$context" == "default" ]]; then
        assert_file_contains "$dir/routed" \
          "CLIENT_HOST=unix://$dir/hostsock " \
          "a $syntax config using default context keeps local routing"
      else
        assert_file_contains "$dir/routed" 'CLIENT_HOST= CLIENT_CONTEXT=' \
          "a $syntax config using a remote context bypasses local routing"
      fi
      assert_file_contains "$dir/routed" "${options[*]} ps" \
        "the final command preserves the $syntax config option unchanged"
    done
  done

  : >"$dir/routed"
  DOCKER_CONFIG="$dir/alternate config" MOCK_ROUTER_CONTEXT=default \
    run_router "$dir" docker ps
  assert_file_contains "$dir/routed" 'CLIENT_HOST= CLIENT_CONTEXT=' \
    "the router also honors DOCKER_CONFIG context selection"
  stop_router_env "$dir"
}

test_router_cleanup_preserves_unrelated_services() {
  local dir="$TEST_TMPDIR/router-safe-cleanup"
  local podman_pid=""
  local dockerd_pid=""
  local service_pid=""
  make_router_env "$dir" with-dockerd

  bash -c 'while :; do sleep 1; done' \
    'podman system service capsule-unrelated' &
  podman_pid=$!
  bash -c 'while :; do sleep 1; done' \
    'dockerd-rootless capsule-unrelated' &
  dockerd_pid=$!

  run_router "$dir" docker ps >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker use-dockerd >/dev/null 2>&1 || true
  run_router "$dir" capsule-docker stop >/dev/null 2>&1 || true
  stop_router_env "$dir"

  for service_pid in "$podman_pid" "$dockerd_pid"; do
    if kill -0 "$service_pid" 2>/dev/null; then
      pass "router fixtures leave an unrelated service process alive"
    else
      fail "router fixtures leave an unrelated service process alive"
    fi
  done
  assert_file_contains "$dir/routed" 'STOP_REQUEST=-f podman system service' \
    "router tests record the Podman shutdown request without host signalling"
  assert_file_contains "$dir/routed" 'STOP_REQUEST=-f dockerd-rootless' \
    "router tests record the dockerd shutdown request without host signalling"

  kill "$podman_pid" "$dockerd_pid" 2>/dev/null || true
  wait "$podman_pid" 2>/dev/null || true
  wait "$dockerd_pid" 2>/dev/null || true
}

test_router_client_only_compose_without_engine() {
  local dir="$TEST_TMPDIR/router-offline-compose"
  local required=""
  local command=""
  local options=()
  make_router_env "$dir"

  for required in 0 1; do
    for command in version config configured joined help bare empty missing; do
      case "$command" in
        version) options=(compose version --short) ;;
        config) options=(compose config --services) ;;
        configured)
          options=(compose -f "$dir/project.yml" -p project --profile dev
            --env-file "$dir/env" --project-directory "$dir"
            --ansi never --parallel 2 --progress plain config)
          ;;
        joined) options=(compose "--file=$dir/project.yml" config) ;;
        help) options=(compose --help) ;;
        bare) options=(compose) ;;
        empty) options=(compose --file '' config) ;;
        missing) options=(compose --file) ;;
      esac
      : >"$dir/routed"
      if DOCKER_HOST="unix://$dir/hostsock" \
        CAPSULE_REQUIRE_HOST_DOCKER="$required" \
        run_router "$dir" docker "${options[@]}" \
        >"$dir/out" 2>"$dir/err"; then
        pass "Compose $command reaches its client with host required=$required"
      else
        fail "Compose $command reaches its client with host required=$required"
      fi
      assert_file_contains "$dir/routed" "ARGS=${options[*]}" \
        "offline Compose $command preserves its arguments"
      if [[ -e "$dir/state/podman.sock" || -e "$dir/state/dockerd.sock" ]]; then
        fail "offline Compose $command never starts an engine"
      else
        pass "offline Compose $command never starts an engine"
      fi
    done
  done

  for command in up ps build run; do
    : >"$dir/routed"
    options=(compose --profile config "$command")
    [[ "$command" != run ]] || options+=(service echo config)
    if CAPSULE_REQUIRE_HOST_DOCKER=1 \
      run_router "$dir" docker "${options[@]}" \
      >"$dir/out" 2>"$dir/err"; then
      fail "Compose $command still refuses an unavailable required engine"
    else
      pass "Compose $command still refuses an unavailable required engine"
    fi
    assert_file_contains "$dir/err" \
      'requested host Docker socket is unavailable' \
      "Compose $command keeps daemon operations fail-closed"
  done
  stop_router_env "$dir"
}

test_entrypoint_inner_storage_ownership() {
  local dir="$TEST_TMPDIR/inner-storage-ownership"
  local namespace=()
  local uid_start=""
  local gid_start=""
  local account=""
  local function_name=""
  if ! command -v unshare >/dev/null 2>&1; then
    skip "inner-storage capability checks need unshare"
    return
  fi
  if ! command -v setpriv >/dev/null 2>&1; then
    skip "inner-storage permission checks need setpriv"
    return
  fi
  if [[ "$(id -u)" != 0 ]]; then
    namespace=(unshare --user --map-auto --map-root-user)
    if command -v getsubids >/dev/null 2>&1; then
      account="$(id -un)"
      uid_start="$(getsubids "$account" 2>/dev/null |
        awk '$4 >= 30018 {print $3; exit}' || true)"
      gid_start="$(getsubids -g "$account" 2>/dev/null |
        awk '$4 >= 30018 {print $3; exit}' || true)"
      if [[ -n "$uid_start" && -n "$gid_start" ]]; then
        namespace=(unshare --user --map-root-user
          "--map-users=$uid_start,1,30000"
          "--map-users=$((uid_start + 30000)),100000,16"
          "--map-users=$((uid_start + 30016)),165535,2"
          "--map-groups=$gid_start,1,30000"
          "--map-groups=$((gid_start + 30000)),100000,16"
          "--map-groups=$((gid_start + 30016)),165535,2")
      fi
    fi
    if ! "${namespace[@]}" setpriv --reuid=23456 --regid=23456 \
      --clear-groups true 2>/dev/null; then
      skip "inner-storage permission checks need a mapped user namespace"
      return
    fi
  elif ! unshare --user --map-root-user true 2>/dev/null; then
    skip "inner-storage capability checks need user namespaces"
    return
  fi
  if ! command -v cc >/dev/null 2>&1; then
    skip "inner-storage metadata checks need a C compiler"
    return
  fi

  mkdir -p "$dir"
  if ! cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$ROOT_DIR/docker/remap-storage.c" -o "$dir/remap-storage" \
    >"$dir/compile-log" 2>&1 ||
    ! cc -std=c11 -O2 -Wall -Wextra -Werror \
      "$ROOT_DIR/tests/fixtures/storage-capabilities.c" -o "$dir/cap-probe" \
      >>"$dir/compile-log" 2>&1 ||
    ! cc -std=c11 -O2 -Wall -Wextra -Werror -shared -fPIC \
      -DFAIL_CAPABILITY_RESTORE \
      "$ROOT_DIR/tests/fixtures/storage-capabilities.c" \
      -o "$dir/cap-failure.so" \
      >>"$dir/compile-log" 2>&1; then
    fail "inner-storage native helpers compile without warnings"
    cat "$dir/compile-log" >&2
    return
  fi
  printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' >"$dir/check"
  sed -n '/^SUBORDINATE_ID_COUNT=/p' "$ENTRYPOINT_PATH" >>"$dir/check"
  for function_name in subordinate_id_start check_inner_storage_mapping \
    prepare_inner_storage; do
    sed -n "/^$function_name() {/,/^}/p" "$ENTRYPOINT_PATH" |
      sed "s|/usr/local/libexec/capsule/remap-storage|$dir/remap-storage|g" \
      >>"$dir/check"
  done
  cat >>"$dir/check" <<'EOF'
root="$1"
umask 077
trap 'chown -Rh 0:0 "$root"' EXIT
trap 'printf "ownership check failed at line %s\n" "$LINENO" >&2' ERR
mkdir -p "$root/storage/containers/layers" "$root/storage/docker"
chmod 755 "$root/storage/containers" "$root/storage/containers/layers"
touch "$root/storage/containers/layers/subordinate"
touch "$root/storage/containers/user-owned" "$root/storage/docker/group-owned"
touch "$root/storage/containers/setuid" "$root/storage/containers/setgid"
touch "$root/storage/docker/group-setuid"
touch "$root/storage/containers/layers/subordinate-setid"
touch "$root/storage/containers/"$'setid\nwith spaces'
ln "$root/storage/containers/setuid" "$root/storage/containers/hardlink"
touch "$root/guard"
ln -s "$root/guard" "$root/storage/link"
ln -s "$root/missing" "$root/storage/dangling"
chown -Rh 1000:100 "$root/storage"
chown 12345:23456 "$root/storage/containers/layers/subordinate"
chown 1000:23456 "$root/storage/containers/user-owned"
chown 12345:100 "$root/storage/docker/group-owned"
chown 1000:23456 "$root/storage/containers/setgid"
chown 12345:100 "$root/storage/docker/group-setuid"
chown 12345:23456 "$root/storage/containers/layers/subordinate-setid"
chown 1000:100 "$root/guard"
chmod 4755 "$root/storage/containers/setuid"
chmod 2755 "$root/storage/containers/setgid"
chmod 4755 "$root/storage/docker/group-setuid"
chmod 6755 "$root/storage/containers/layers/subordinate-setid"
chmod 6755 "$root/storage/containers/"$'setid\nwith spaces'
chmod 2775 "$root/storage" "$root/storage/docker"
chmod 6755 "$root/guard"

for name in cap-plain cap-namespaced cap-subordinate cap-foreign cap-setid; do
  cp "$root/cap-probe" "$root/storage/containers/$name"
done
touch "$root/storage/containers/cap-empty" "$root/storage/containers/cap-rich"
chown 1000:100 "$root/storage/containers/"cap-*
chown 12345:23456 "$root/storage/containers/cap-subordinate"
chmod 755 "$root/storage/containers/"cap-*
chmod 4755 "$root/storage/containers/cap-setid"
"$root/cap-probe" set "$root/storage/containers/cap-plain" 0
"$root/cap-probe" set "$root/storage/containers/cap-namespaced" 1000
"$root/cap-probe" set "$root/storage/containers/cap-subordinate" 1000
"$root/cap-probe" set "$root/storage/containers/cap-foreign" 12345
"$root/cap-probe" set "$root/storage/containers/cap-setid" 1000
"$root/cap-probe" empty "$root/storage/containers/cap-empty" 1000
"$root/cap-probe" set-rich "$root/storage/containers/cap-rich" 1000
ln "$root/storage/containers/cap-namespaced" \
  "$root/storage/containers/cap-hardlink"
"$root/cap-probe" set "$root/guard" 1000
cd "$root/storage"
setpriv --reuid=1000 --regid=100 --clear-groups containers/cap-plain

execute_with_namespace() {
  unshare --user --map-users="$2,0,1" --map-users=5000,1,1 \
    --map-groups="$3,0,1" --map-groups=5000,1,1 \
    --setuid=1 --setgid=1 "$1"
}
execute_with_namespace containers/cap-namespaced 1000 100

check_storage_capabilities() {
  "$root/cap-probe" check containers/cap-plain 0
  "$root/cap-probe" check containers/cap-namespaced "$1"
  "$root/cap-probe" check containers/cap-hardlink "$1"
  "$root/cap-probe" check containers/cap-subordinate "$1"
  "$root/cap-probe" check containers/cap-foreign 12345
  "$root/cap-probe" check containers/cap-setid "$1"
  "$root/cap-probe" check-empty containers/cap-empty "$1"
  "$root/cap-probe" check-rich containers/cap-rich "$1"
  "$root/cap-probe" check "$root/guard" 1000
  [[ "$(stat -c '%u:%g:%a' containers/cap-setid)" == "$1:$2:4755" ]]
  [[ "$(stat -c '%u:%g' containers/cap-subordinate)" == 12345:23456 ]]
  cmp "$root/cap-probe" containers/cap-namespaced
  setpriv --reuid="$1" --regid="$2" --clear-groups containers/cap-plain
  execute_with_namespace containers/cap-namespaced "$1" "$2"
  execute_with_namespace containers/cap-subordinate "$1" "$2"
  if execute_with_namespace containers/cap-foreign "$1" "$2" \
    >"$root/foreign-log" 2>&1; then
    printf 'foreign namespace capabilities must not be granted\n' >&2
    exit 1
  fi
  grep -Fxq 'effective CAP_NET_RAW is missing' "$root/foreign-log"
}

check_storage_modes() {
  check_storage_capabilities "$1" "$2"
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/containers/setuid")" == "$1:$2:4755" ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/containers/hardlink")" == "$1:$2:4755" ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/containers/setgid")" == "$1:23456:2755" ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/docker/group-setuid")" == "12345:$2:4755" ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/containers/layers/subordinate-setid")" == 12345:23456:6755 ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$root/storage/containers/"$'setid\nwith spaces')" == "$1:$2:6755" ]]
  [[ "$(stat -c '%u:%g:%a' "$root/storage")" == "$1:$2:2775" ]]
  [[ "$(stat -c '%u:%g:%a' "$root/storage/docker")" == "$1:$2:2775" ]]
  [[ "$(stat -c '%u:%g:%a' "$root/guard")" == 1000:100:6755 ]]
  [[ "$(stat -c '%u:%g' "$root/storage/dangling")" == "$1:$2" ]]
  [[ "$(readlink "$root/storage/dangling")" == "$root/missing" ]]
  [[ ! -e "$root/storage/.capsule-owner-migration" ]]
}

TARGET_UID=2000 TARGET_GID=2000 prepare_inner_storage "$root/storage"
check_storage_modes 2000 2000
[[ "$(stat -c '%u:%g' "$root/storage")" == 2000:2000 ]]
[[ "$(stat -c '%u:%g' "$root/storage/containers/user-owned")" == 2000:23456 ]]
[[ "$(stat -c '%u:%g' "$root/storage/docker/group-owned")" == 12345:2000 ]]
[[ "$(stat -c '%u:%g' "$root/storage/containers/layers/subordinate")" == \
  12345:23456 ]]
[[ "$(stat -c '%u:%g' "$root/guard")" == 1000:100 ]]
[[ "$(stat -c '%u:%g' "$root/storage/link")" == 2000:2000 ]]
cd "$root/storage"
setpriv --reuid=2000 --regid=2000 --clear-groups \
  sh -c 'mkdir containers/runtime-write docker/runtime-write'
printf 'remapped runtime can write both engine roots\n'

TARGET_UID=3000 TARGET_GID=3000 prepare_inner_storage "$root/storage"
check_storage_modes 3000 3000
[[ "$(stat -c '%u:%g' "$root/storage/containers/runtime-write")" == 3000:3000 ]]
[[ "$(stat -c '%u:%g' "$root/storage/containers/layers/subordinate")" == \
  12345:23456 ]]
[[ "$(stat -c '%u:%g' "$root/guard")" == 1000:100 ]]
setpriv --reuid=3000 --regid=3000 --clear-groups \
  sh -c 'mkdir containers/second-write docker/second-write'
TARGET_UID=3000 TARGET_GID=3000 prepare_inner_storage "$root/storage"
check_storage_modes 3000 3000
TARGET_UID=3000 TARGET_GID=4000 prepare_inner_storage "$root/storage"
check_storage_modes 3000 4000
TARGET_UID=4000 TARGET_GID=4000 prepare_inner_storage "$root/storage"
check_storage_modes 4000 4000
printf 'storage remapping preserves set-ID file and directory modes\n'
printf 'storage remapping preserves capabilities and namespace root IDs\n'
printf 'existing runtime state migrates without changing subordinate owners\n'

TARGET_UID=2000 TARGET_GID=2000 prepare_inner_storage "$root/fresh"
[[ "$(stat -c '%u:%g' "$root/fresh")" == 2000:2000 ]]
printf 'missing storage root is created with the runtime identity\n'

[[ "$(subordinate_id_start 99999)" == 100000 ]]
[[ "$(subordinate_id_start 100000)" == 100001 ]]
[[ "$(subordinate_id_start 0100001)" == 100002 ]]
[[ "$(subordinate_id_start 165535)" == 165536 ]]
[[ "$(subordinate_id_start 165536)" == 100000 ]]

read_range_data() {
  local storage_dir="$1"
  local uid_start="$(subordinate_id_start "$2")"
  local gid_start="$(subordinate_id_start "$3")"
  (cd "$storage_dir" &&
    unshare --user --map-users="$2,0,1" --map-users="$uid_start,1,1" \
      --map-groups="$3,0,1" --map-groups="$gid_start,1,1" \
      --setuid=1 --setgid=1 cat containers/volumes/app/_data/data)
}

reject_range_change() {
  local storage_dir="$root/ranges-$1-$2-$3-$4"
  local uid_start="$(subordinate_id_start "$1")"
  local gid_start="$(subordinate_id_start "$2")"
  mkdir -p "$storage_dir/containers/volumes/app/_data"
  find "$storage_dir" -type d -exec chmod 755 {} +
  printf 'application-data\n' >"$storage_dir/containers/volumes/app/_data/data"
  chown "$1:$2" "$storage_dir"
  chown "$uid_start:$gid_start" \
    "$storage_dir/containers/volumes/app/_data/data"
  chmod 600 "$storage_dir/containers/volumes/app/_data/data"
  [[ "$(read_range_data "$storage_dir" "$1" "$2")" == application-data ]]
  if TARGET_UID="$3" TARGET_GID="$4" \
    prepare_inner_storage "$storage_dir" >"$root/range-log" 2>&1; then
    printf 'unsafe subordinate range change was accepted\n' >&2
    exit 1
  fi
  grep -Fq 'cannot change subordinate ID ranges' "$root/range-log"
  grep -Fq "CAPSULE_UID=$1 CAPSULE_GID=$2" "$root/range-log"
  [[ "$(stat -c '%u:%g' "$storage_dir")" == "$1:$2" ]]
  [[ "$(stat -c '%u:%g:%a' \
    "$storage_dir/containers/volumes/app/_data/data")" == \
    "$uid_start:$gid_start:600" ]]
  [[ ! -e "$storage_dir/.capsule-owner-migration" ]]
  TARGET_UID="$1" TARGET_GID="$2" prepare_inner_storage "$storage_dir"
  [[ "$(read_range_data "$storage_dir" "$1" "$2")" == application-data ]]
}

if setpriv --reuid=165536 --regid=165536 --clear-groups true 2>/dev/null; then
  reject_range_change 1000 100 100001 2000
  reject_range_change 100001 2000 1000 100
  reject_range_change 100001 2000 100002 2000
  reject_range_change 1000 100 1000 100001
  reject_range_change 1000 100001 1000 100
  reject_range_change 1000 100001 1000 100002
  reject_range_change 1000 100 100000 100
  reject_range_change 165535 100 165536 100
  reject_range_change 1000 165535 1000 165536
  TARGET_UID=100001 TARGET_GID=100 \
    prepare_inner_storage "$root/empty-high-storage"
  [[ "$(stat -c '%u:%g' "$root/empty-high-storage")" == 100001:100 ]]
  touch "$root/empty-high-storage/retained"
  TARGET_UID=100001 TARGET_GID=2000 \
    prepare_inner_storage "$root/empty-high-storage"
  [[ "$(stat -c '%u:%g' "$root/empty-high-storage")" == 100001:2000 ]]
  mkdir "$root/empty-existing-storage"
  chown 1000:100 "$root/empty-existing-storage"
  TARGET_UID=100001 TARGET_GID=100001 \
    prepare_inner_storage "$root/empty-existing-storage"
  [[ "$(stat -c '%u:%g' "$root/empty-existing-storage")" == 100001:100001 ]]
  touch "$root/empty-existing-storage/retained"
  TARGET_UID=100001 TARGET_GID=100001 \
    prepare_inner_storage "$root/empty-existing-storage"
  mkdir "$root/upper-bound-storage"
  chown 1000:100 "$root/upper-bound-storage"
  touch "$root/upper-bound-storage/retained"
  TARGET_UID=165536 TARGET_GID=165536 \
    prepare_inner_storage "$root/upper-bound-storage"
  [[ "$(stat -c '%u:%g' "$root/upper-bound-storage")" == 165536:165536 ]]
  printf 'retained storage refuses range changes without changing data\n'
else
  printf 'high-ID range checks need additional user-namespace mappings\n'
fi

if "$root/remap-storage" >"$root/error-log" 2>&1; then
  printf 'missing migration arguments were accepted\n' >&2
  exit 1
fi
grep -Fq 'usage:' "$root/error-log"
for invalid in '' -1 +1 1x 4294967295 4294967296 999999999999999999999; do
  if "$root/remap-storage" "$invalid" 100 2000 2000 "$root/guard" \
    >"$root/error-log" 2>&1; then
    printf 'invalid owner ID was accepted: %s\n' "$invalid" >&2
    exit 1
  fi
  grep -Fq 'invalid storage owner ID' "$root/error-log"
done
if "$root/remap-storage" 1000 100 2000 2000 "$root/missing" \
  >"$root/error-log" 2>&1; then
  printf 'missing storage entry was accepted\n' >&2
  exit 1
fi
mkdir "$root/failed-storage"
chown 1000:100 "$root/failed-storage"
failure_script="SUBORDINATE_ID_COUNT=$SUBORDINATE_ID_COUNT"
failure_script+=$'\n'"$(declare -f subordinate_id_start \
  check_inner_storage_mapping prepare_inner_storage)"
failure_script+=$'\nfind() {\n'
failure_script+=$'case " $* " in *" -xdev "*) return 1;; esac'
failure_script+=$'\ncommand find "$@"\n}\nprepare_inner_storage "$1"'
if TARGET_UID=2000 TARGET_GID=2000 bash -ec "$failure_script" \
  bash "$root/failed-storage" >"$root/error-log" 2>&1; then
  printf 'failed traversal was accepted\n' >&2
  exit 1
fi
[[ "$(stat -c '%u:%g' "$root/failed-storage")" == 1000:100 ]]
[[ -d "$root/failed-storage/.capsule-owner-migration" ]]
if TARGET_UID=1000 TARGET_GID=100 \
  prepare_inner_storage "$root/failed-storage" >"$root/error-log" 2>&1; then
  printf 'unfinished migration was accepted with unchanged IDs\n' >&2
  exit 1
fi
grep -Fq 'unfinished storage migration' "$root/error-log"

mkdir "$root/rollback-storage"
cp "$root/cap-probe" "$root/rollback-storage/cap"
chown -R 1000:100 "$root/rollback-storage"
chmod 4755 "$root/rollback-storage/cap"
"$root/cap-probe" set "$root/rollback-storage/cap" 1000
if LD_PRELOAD="$root/cap-failure.so" TARGET_UID=2000 TARGET_GID=2000 \
  prepare_inner_storage "$root/rollback-storage" >"$root/error-log" 2>&1; then
  printf 'capability restore failure was accepted\n' >&2
  exit 1
fi
[[ "$(stat -c '%u:%g' "$root/rollback-storage")" == 1000:100 ]]
[[ "$(stat -c '%u:%g:%a' "$root/rollback-storage/cap")" == 1000:100:4755 ]]
"$root/cap-probe" check "$root/rollback-storage/cap" 1000
[[ -d "$root/rollback-storage/.capsule-owner-migration" ]]
rmdir "$root/rollback-storage/.capsule-owner-migration"
TARGET_UID=2000 TARGET_GID=2000 prepare_inner_storage "$root/rollback-storage"
[[ "$(stat -c '%u:%g:%a' "$root/rollback-storage/cap")" == 2000:2000:4755 ]]
"$root/cap-probe" check "$root/rollback-storage/cap" 2000
printf 'storage migration errors fail closed without advancing root owners\n'
EOF

  if ${namespace[@]+"${namespace[@]}"} bash "$dir/check" "$dir" \
    >"$dir/out" 2>"$dir/err"; then
    assert_file_contains "$dir/out" 'remapped runtime can write' \
      "runtime UID/GID remapping keeps both engine roots writable"
    assert_file_contains "$dir/out" 'existing runtime state migrates' \
      "storage migrations preserve subordinate ownership and symlink targets"
    assert_file_contains "$dir/out" 'storage remapping preserves set-ID' \
      "storage migrations preserve set-ID modes across UID/GID changes"
    assert_file_contains "$dir/out" 'storage remapping preserves capabilities' \
      "storage migrations preserve file and effective namespaced capabilities"
    assert_file_contains "$dir/out" 'missing storage root is created' \
      "a new storage directory receives the runtime identity"
    assert_file_contains "$dir/out" 'storage migration errors fail closed' \
      "failed storage migrations cannot silently resume with damaged metadata"
    if grep -Fq 'high-ID range checks need' "$dir/out"; then
      skip "high-ID range checks need additional user-namespace mappings"
    else
      assert_file_contains "$dir/out" 'retained storage refuses range changes' \
        "unsafe UID/GID range changes preserve container-user data access"
    fi
  else
    fail "inner-storage runtime ownership checks"
    cat "$dir/err" >&2
  fi
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

test_router_requires_requested_host_socket() {
  local state=""
  local dir="$TEST_TMPDIR/router-required-host"
  make_router_env "$dir"

  for state in missing inaccessible; do
    if [[ "$state" == "inaccessible" ]]; then
      : >"$dir/hostsock"
    fi
    if CAPSULE_REQUIRE_HOST_DOCKER=1 ROUTER_BROKEN_SOCKET="$dir/hostsock" \
      run_router "$dir" docker ps >"$dir/out" 2>&1; then
      fail "a requested $state host socket fails closed"
    else
      pass "a requested $state host socket fails closed"
    fi
    assert_file_contains "$dir/out" \
      'requested host Docker socket is unavailable' \
      "a requested $state host socket reports its failure"
    if [[ -e "$dir/state/podman.sock" || -e "$dir/routed" ]]; then
      fail "a requested $state host socket never starts an inner engine"
    else
      pass "a requested $state host socket never starts an inner engine"
    fi
  done

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

test_nested_subordinate_id_ranges() {
  local tdir="$TEST_TMPDIR/subordinate-ids"
  local setup_script=""
  local account_id=""
  local id_type=""
  mkdir -p "$tdir"

  setup_script="$(awk '
    /^RUN for id_type in uid gid; do/ { copying = 1 }
    copying && /    done &&/ { print "done"; exit }
    copying { sub(/^RUN /, ""); sub(/\\$/, ""); print }
  ' "$DOCKERFILE_PATH")"
  setup_script="${setup_script//\/etc\/sub/$tdir/sub}"

  for account_id in 0 100 1000 65534 65536 70000; do
    CAPSULE_UID="$account_id" CAPSULE_GID="$account_id" \
      bash -ec "$setup_script"
    for id_type in uid gid; do
      if [[ -s "$tdir/sub$id_type" ]] && \
        awk -F: -v account_id="$account_id" '
          $1 != "user" || $2 < 0 || $3 <= 0 { invalid = 1 }
          $2 + $3 > 65537 { invalid = 1 }
          $2 <= account_id && account_id < $2 + $3 { invalid = 1 }
          NR > 1 && $2 < previous_end { invalid = 1 }
          { total += $3; previous_end = $2 + $3 }
          END { exit invalid || total != 65536 }
        ' "$tdir/sub$id_type"; then
        pass "nested $id_type ranges fit keep-id for account $account_id"
      else
        fail "nested $id_type ranges fit keep-id for account $account_id"
      fi
    done
  done
}

# shellcheck disable=SC2016
test_podman_image_contract() {
  assert_file_contains "$DOCKERFILE_PATH" \
    'aardvark-dns catatonit fuse-overlayfs netavark nftables passt podman' \
    "Dockerfile installs what the inner engine needs to serve a project"
  test_nested_subordinate_id_ranges
  assert_file_contains "$DOCKERFILE_PATH" \
    'ln -s /usr/local/bin/capsule-docker /usr/local/bin/docker' \
    "Dockerfile puts the engine router ahead of the real client"
  assert_file_contains "$DOCKERFILE_PATH" \
    'ARG CAPSULE_WITH_DOCKERD=0' \
    "Dockerfile keeps the real Engine behind a build arg"
  assert_file_contains "$DOCKERFILE_PATH" \
    'type=secret,id=github_api_token' \
    "Dockerfile mounts the build token as a secret file"
  assert_file_not_contains "$DOCKERFILE_PATH" 'required=true' \
    "Dockerfile accepts a missing GitHub token secret"
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
  if ! bash -n "$PROFILE_CORE_PATH"; then
    fail "profile parser has valid shell syntax"
  else
    pass "profile parser has valid shell syntax"
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
  test_doctor_checks_gid_capacity
  test_github_token_is_optional
  test_ci_runs_nested_capsules_for_each_backend
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
  test_list_debug_trace_hides_container_secrets
  test_list_labels_implicit_remote_docker_endpoints
  test_list_queries_remote_docker_without_workdir_or_approval
  test_list_rejects_launch_commands
  test_remote_flag_requires_authorization
  test_run_confirmation_supports_only_once
  test_default_config_uses_xdg_location
  test_relative_xdg_paths_are_rejected
  test_legacy_config_is_migrated
  test_legacy_config_symlink_is_rejected
  test_legacy_config_migration_resumes
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
  test_debug_mode_redacts_github_token
  test_token_presence_checks_do_not_expand_values
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
  test_profile_runtime_settings
  test_profile_honors_compose_project_name
  test_docker_profile_preserves_piped_stdin
  test_docker_runtime_forwards_signals
  test_profile_names_resolve_from_xdg_config
  test_profile_names_fall_back_to_bundled_profiles
  test_duplicate_profile_directories_are_ignored
  test_profile_volumes_use_host_path_map
  test_nested_profile_home_volumes_use_host_visible_home
  test_nested_profile_home_volume_requires_host_visible_home
  test_profile_home_volume_uses_remote_home
  test_profile_home_volume_rejects_missing_remote_home
  test_remote_profile_volume_source_rules
  test_profile_custom_build_generates_ordered_image
  test_generated_profile_files_are_cached_by_output
  test_profile_build_preserves_selected_order
  test_profile_accepts_multiline_eof_without_newline
  test_profile_rejects_unsupported_toml
  test_profiles_conflict_with_custom_compose
  test_profile_option_rejects_empty_selector
  test_podman_backend_runs_container_with_keep_id
  test_podman_preserves_piped_stdin
  test_podman_profile_runtime_settings
  test_podman_profile_image_includes_base_identity
  test_nested_capsule_podman_uses_local_workdir
  test_podman_inner_volume_is_per_workspace
  test_podman_backend_translates_publish_and_volume
  test_podman_backend_mounts_the_token_secret
  test_podman_host_docker_is_opt_in
  test_podman_host_docker_without_a_socket_is_an_error
  test_host_docker_requires_group_support
  test_podman_build_uses_docker_format_and_a_secret
  test_podman_backend_requires_built_image
  test_podman_falls_back_when_rootful
  test_explicit_podman_does_not_fall_back
  test_podman_checks_uid_and_gid_capacity
  test_podman_falls_back_without_a_subid_range
  test_podman_falls_back_when_engine_unreachable
  test_podman_falls_back_for_remote_and_custom_compose
  test_podman_on_macos_requires_workspace_under_home
  test_podman_on_macos_requires_profiles_under_home
  test_podman_on_macos_requires_profile_volumes_under_home
  test_podman_on_macos_runs_a_workspace_under_home
  test_runtime_docker_keeps_docker_with_podman_available
  test_runtime_flag_rejects_bad_values
  test_router_starts_the_podman_socket_on_first_use
  test_router_reports_engine_status
  test_router_switch_to_dockerd_sticks
  test_router_reports_a_missing_dockerd
  test_router_prefers_a_bound_host_socket
  test_router_preserves_explicit_endpoints
  test_router_honors_alternate_config
  test_nested_remote_commands_use_router
  test_nested_commands_use_generated_podman_environment
  test_router_cleanup_preserves_unrelated_services
  test_router_client_only_compose_without_engine
  test_router_ignores_a_dead_host_socket
  test_router_requires_requested_host_socket
  test_router_stop_releases_the_engines
  test_entrypoint_non_root_path_execs_the_command
  test_entrypoint_inner_storage_ownership
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
