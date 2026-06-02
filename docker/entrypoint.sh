#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------
# Runtime UID/GID adjustment entrypoint.
#
# When running as root (the default), this script:
#   1. Adjusts the "user" account to match CAPSULE_UID/CAPSULE_GID.
#   2. Adds "user" to the DOCKER_GID group for socket access.
#   3. Fixes ownership of /home/user when the UID/GID changed OR
#      a named volume has stale ownership from a previous image build.
#   4. Sets HOME, USER, and LOGNAME (setpriv does not update
#      environment variables, so they would otherwise stay as
#      root's values from the Dockerfile USER directive).
#   5. Drops privileges via setpriv and execs the command.
#
# When running as non-root (e.g. --user flag), skips all
# adjustments and execs the command directly.
# ----------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

CUR_UID="$(id -u user)"
CUR_GID="$(id -g user)"
TARGET_UID="${CAPSULE_UID:-$CUR_UID}"
TARGET_GID="${CAPSULE_GID:-$CUR_GID}"
CHANGED=0

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

# Get `gh` path before rewriting HOME
GH="$(mise --cd /root which gh)"

# Set user environment before dropping privileges.
# setpriv does not update env vars, so HOME, USER, and
# LOGNAME would otherwise stay as root's values.
USER_HOME="$(getent passwd user | cut -d: -f6)"
export HOME="${USER_HOME:-/home/user}"
export USER=user
export LOGNAME=user

# Export GitHub token and authenticate when a runtime secret is
# present.  This makes the token available to all child processes
# (curl, docker, etc.) and avoids API throttling.
_GH_SECRET=/run/secrets/github_api_token
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
