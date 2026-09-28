#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------
# Runtime UID/GID adjustment entrypoint.
#
# When running as root (the Docker backend's default), this script:
#   1. Adjusts the "user" account to match CAPSULE_UID/CAPSULE_GID.
#   2. Gives rootless Podman a complete subordinate UID/GID range.
#   3. Adds "user" to the DOCKER_GID group for socket access.
#   4. Fixes ownership of /home/user when the UID/GID changed OR
#      a named volume has stale ownership from a previous image build.
#   5. Sets HOME, USER, and LOGNAME (setpriv does not update
#      environment variables, so they would otherwise stay as
#      root's values from the Dockerfile USER directive).
#   6. Drops privileges via setpriv and execs the command.
#
# When running as non-root it execs the command directly. That is the
# normal case on the podman backend, where the container starts as
# "user" already: podman's keep-id mapping makes that account the
# host user, so there is no id to adjust and no privilege to drop.
# The GitHub credential refresh happens on both paths, because it
# needs the runtime secret rather than root.
# ----------------------------------------------------------------

# Resolve the gh binary for the runtime auth refresh below. Prefer a direct
# system binary, then ask mise from / so it uses the system configuration
# instead of any workspace settings. Both root and the podman user can read /.
GH=/usr/local/bin/gh
[ -x "$GH" ] || GH="$(mise --cd / which gh 2>/dev/null || true)"

# Export the GitHub token and refresh gh's credentials from the runtime
# secret, so every child process (curl, docker, the agents) is authenticated
# and avoids API throttling.
_GH_SECRET=/run/secrets/github_api_token
refresh_gh_auth() {
  [ -s "$_GH_SECRET" ] || return 0

  GITHUB_API_TOKEN="$(cat "$_GH_SECRET")"
  export GITHUB_API_TOKEN
  "$GH" auth login --with-token <"$_GH_SECRET" \
    || printf 'capsule: warning: gh auth login failed\n' >&2
}

# Give commands the image account's environment on both entrypoint paths.
# The lookup is best-effort: this runs on the non-root path too, which the
# test suite exercises on the host, where getent need not exist. The image
# account lives in /home/user by construction, so that is the fallback.
set_user_environment() {
  local user_home=""

  user_home="$(getent passwd user 2>/dev/null | cut -d: -f6 || true)"
  export HOME="${user_home:-/home/user}"
  export USER=user
  export LOGNAME=user
}

if [ "$(id -u)" != "0" ]; then
  set_user_environment
  refresh_gh_auth
  exec "$@"
fi

CUR_UID="$(id -u user)"
CUR_GID="$(id -g user)"
TARGET_UID="${CAPSULE_UID:-$CUR_UID}"
TARGET_GID="${CAPSULE_GID:-$CUR_GID}"
CHANGED=0

# Give nested rootless Podman every ordinary container ID, including Debian's
# 65534 nobody account. The smaller image-time range must fit inside an outer
# rootless Podman namespace; the Docker backend has no such parent mapping, so
# its root entrypoint can safely replace that range with the standard size.
SUBORDINATE_ID_COUNT=65536
SUBORDINATE_UID_START=100000
SUBORDINATE_GID_START=100000
if [ "$TARGET_UID" -ge "$SUBORDINATE_UID_START" ] && \
   [ "$TARGET_UID" -lt $((SUBORDINATE_UID_START + SUBORDINATE_ID_COUNT)) ]; then
  SUBORDINATE_UID_START=$((TARGET_UID + 1))
fi
if [ "$TARGET_GID" -ge "$SUBORDINATE_GID_START" ] && \
   [ "$TARGET_GID" -lt $((SUBORDINATE_GID_START + SUBORDINATE_ID_COUNT)) ]; then
  SUBORDINATE_GID_START=$((TARGET_GID + 1))
fi
printf 'user:%s:%s\n' \
  "$SUBORDINATE_UID_START" "$SUBORDINATE_ID_COUNT" >/etc/subuid
printf 'user:%s:%s\n' \
  "$SUBORDINATE_GID_START" "$SUBORDINATE_ID_COUNT" >/etc/subgid

# Adjust primary group GID when it differs.
if [ "$CUR_GID" != "$TARGET_GID" ]; then
  if ! getent group "$TARGET_GID" >/dev/null 2>&1; then
    groupadd -g "$TARGET_GID" capsule
  fi
  usermod -g "$TARGET_GID" user
  CHANGED=1
fi

# Adjust user UID when it differs.
if [ "$CUR_UID" != "$TARGET_UID" ]; then
  usermod -u "$TARGET_UID" user
  CHANGED=1
fi

# Add user to the Docker socket group when requested.
if [ -n "${DOCKER_GID:-}" ]; then
  DK_GROUP="$(getent group "$DOCKER_GID" \
    | cut -d: -f1 || true)"
  if [ -z "$DK_GROUP" ]; then
    groupadd -g "$DOCKER_GID" docker_host
    DK_GROUP="docker_host"
  fi
  usermod -aG "$DK_GROUP" user
fi

# Fix ownership when UID/GID changed or a named volume has
# stale ownership from a previous image build.
TARGET_HOME="$(getent passwd user | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/home/user}"
OWNER_UID="$(stat -c '%u' "$TARGET_HOME" 2>/dev/null || true)"
if [ "$CHANGED" = "1" ] || \
   [ "${OWNER_UID:-}" != "$(id -u user)" ]; then
  printf 'capsule: adjusting file ownership...\n' >&2
  chown -Rh user: "$TARGET_HOME" 2>/dev/null || true
fi

# setpriv does not update environment variables, so initialize them before
# dropping privileges instead of leaving root's values in place.
set_user_environment

# Export GitHub token and authenticate when a runtime secret is
# present.  This makes the token available to all child processes
# (curl, docker, etc.) and avoids API throttling.
if [ -s "$_GH_SECRET" ]; then
    GITHUB_API_TOKEN="$(cat "$_GH_SECRET")"
    export GITHUB_API_TOKEN
    setpriv \
        --reuid="$(id -u user)" \
        --regid="$(id -g user)" \
        --init-groups \
        -- "$GH" auth login --with-token < "$_GH_SECRET" \
        || printf 'capsule: warning: gh auth login failed\n' >&2
fi

exec setpriv \
  --reuid="$(id -u user)" \
  --regid="$(id -g user)" \
  --init-groups \
  -- "$@"
