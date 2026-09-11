#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Refresh Graphify's vendor and Capsule lifecycle skills in each bundled
# agent's persistent home. A content-aware stamp avoids repeated writes.
# Failures remain non-fatal so optional skill setup cannot block startup.
#
# Skills live in the persistent home volume while Graphify lives in the
# image, so the two drift whenever an image without Graphify runs against an
# older home. Capsule's own lifecycle skill therefore syncs unconditionally,
# and a missing Graphify is reported instead of silently skipped: a quiet
# success is what lets a stale skill point agents at an absent command.
#-------------------------------------------------------------------------------

set -u

readonly VERSION_FILE="/usr/local/share/graphify-version"
readonly HOME_DIR="${HOME:-/home/user}"
readonly STAMP_DIR="$HOME_DIR/.cache/capsule"
readonly STAMP_FILE="$STAMP_DIR/graphify-skills"
readonly CAPSULE_SKILL_DIR="/usr/local/share/capsule-skills/maintain-graphify"

readonly SKILL_ROOTS=(
  "$HOME_DIR/.claude/skills"
  "$HOME_DIR/.codex/skills"
  "$HOME_DIR/.gemini/config/skills"
)

if [[ "${CAPSULE_SKIP_SKILL_SYNC:-}" == "1" ]]; then
  exit 0
fi

# Report the Graphify release this image ships, or "absent" when the binary
# is missing. The stamp embeds it so the sync reruns once Graphify returns.
graphify_release() {
  local release=""

  if ! command -v graphify >/dev/null 2>&1; then
    printf 'absent\n'
    return
  fi

  release="$(cat "$VERSION_FILE" 2>/dev/null)"
  if [[ -z "$release" ]]; then
    release="$(graphify --version 2>/dev/null | awk '{print $NF}')"
  fi
  printf '%s\n' "${release:-unknown}"
}

# Checksum the bundled lifecycle skill so content edits force a resync.
capsule_skill_hash() {
  if [[ ! -d "$CAPSULE_SKILL_DIR" ]]; then
    printf 'missing\n'
    return
  fi

  find "$CAPSULE_SKILL_DIR" -type f -exec cksum {} \; 2>/dev/null \
    | sort \
    | cksum \
    | awk '{print $1}'
}

# Copy Capsule's lifecycle skill into every agent home. This is first-party
# content and must not depend on Graphify being installed.
sync_capsule_skill() {
  local skill_root=""
  local target=""
  local ok=1

  if [[ ! -d "$CAPSULE_SKILL_DIR" ]]; then
    return 0
  fi

  for skill_root in "${SKILL_ROOTS[@]}"; do
    target="$skill_root/maintain-graphify"
    if ! mkdir -p "$target" 2>/dev/null; then
      ok=0
      continue
    fi
    cp -R "$CAPSULE_SKILL_DIR/." "$target/" 2>/dev/null || ok=0
    if [[ "$skill_root" != "$HOME_DIR/.codex/skills" ]]; then
      rm -rf "$target/agents" 2>/dev/null || ok=0
    fi
  done

  return $((1 - ok))
}

# Reinstall Graphify's vendor skill for every bundled agent.
sync_vendor_skills() {
  local platform=""
  local ok=1

  for platform in claude codex antigravity; do
    graphify install --platform "$platform" >/dev/null 2>&1 || ok=0
  done

  return $((1 - ok))
}

release="$(graphify_release)"
current="${release}:$(capsule_skill_hash)"

if [[ -f "$STAMP_FILE" ]] \
     && [[ "$(cat "$STAMP_FILE" 2>/dev/null)" == "$current" ]]; then
  exit 0
fi

cd "$HOME_DIR" || exit 0

sync_ok=1
sync_capsule_skill || sync_ok=0

if [[ "$release" == "absent" ]]; then
  printf 'capsule: warning: graphify is not installed in this image; %s\n' \
    'its agent skills are left as-is and may be stale' >&2
else
  sync_vendor_skills || sync_ok=0
fi

if [[ "$sync_ok" == "1" ]]; then
  mkdir -p "$STAMP_DIR" 2>/dev/null || sync_ok=0
fi
if [[ "$sync_ok" == "1" ]]; then
  printf '%s\n' "$current" >"$STAMP_FILE" 2>/dev/null || true
fi

exit 0
