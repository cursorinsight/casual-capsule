#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Report Graphify setup problems that silently degrade agent answers.
#
# Graphify spans three places that drift independently: the binary in the
# image, the skills in the persistent home volume, and the graph in the
# workspace. Nothing fails loudly when they disagree -- an agent just follows
# stale instructions or queries a stale graph -- so this check states the
# mismatch out loud. It only reports; docker/sync-skills.sh does the fixing.
#
# Every check is advisory: the script always exits 0 so a degraded graph can
# never block a shell.
#-------------------------------------------------------------------------------

set -u

readonly VERSION_FILE="/usr/local/share/graphify-version"
readonly HOME_DIR="${HOME:-/home/user}"
readonly WORKDIR="${1:-$PWD}"

readonly SKILL_PATHS=(
  "$HOME_DIR/.claude/skills/graphify/.graphify_version"
  "$HOME_DIR/.codex/skills/graphify/.graphify_version"
  "$HOME_DIR/.gemini/config/skills/graphify/.graphify_version"
)

if [[ "${CAPSULE_SKIP_GRAPHIFY_DOCTOR:-}" == "1" ]]; then
  exit 0
fi

warn() {
  printf 'capsule: graphify: %s\n' "$*" >&2
}

# Compare the running binary against the version the image recorded, then
# against every installed skill. A skill built for another release describes
# flags and workflows the binary may not have.
check_versions() {
  local pinned=""
  local actual=""
  local installed=""
  local skill_path=""

  if ! command -v graphify >/dev/null 2>&1; then
    warn 'not installed in this image; agent skills that call it will fail'
    warn 'rebuild with "capsule --build" to install the pinned release'
    return
  fi

  pinned="$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null)"
  actual="$(graphify --version 2>/dev/null | awk '{print $NF}')"

  if [[ -n "$pinned" ]] && [[ -n "$actual" ]] \
       && [[ "$pinned" != "$actual" ]]; then
    warn "binary is $actual but the image records $pinned"
  fi

  for skill_path in "${SKILL_PATHS[@]}"; do
    [[ -f "$skill_path" ]] || continue
    installed="$(tr -d '[:space:]' <"$skill_path" 2>/dev/null)"
    if [[ -n "$installed" ]] && [[ -n "$actual" ]] \
         && [[ "$installed" != "$actual" ]]; then
      warn "skill ${skill_path%/.graphify_version} is from $installed," \
        "package is $actual"
    fi
  done
}

# Warn when the graph was built from a commit that is no longer reachable.
# A rebase rewrites hashes, so the graph silently describes an abandoned
# tree; queries keep answering from it without any sign of staleness.
check_graph_commit() {
  local graph="$WORKDIR/graphify-out/graph.json"
  local built=""

  [[ -f "$graph" ]] || return
  command -v git >/dev/null 2>&1 || return
  git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1 || return

  local pattern='.*"built_at_commit"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*'
  built="$(
    sed -n "s/$pattern/\1/p" "$graph" 2>/dev/null | head -n1
  )"
  [[ -n "$built" ]] || return

  if ! git -C "$WORKDIR" cat-file -e "${built}^{commit}" 2>/dev/null; then
    warn "graph was built from unknown commit ${built:0:8}; rebuild it"
    return
  fi

  if ! git -C "$WORKDIR" merge-base --is-ancestor "$built" HEAD 2>/dev/null
  then
    warn "graph was built from ${built:0:8}, which HEAD no longer contains"
    warn 'run "graphify . --update" to rebuild it against the current tree'
  fi
}

check_versions
check_graph_commit

exit 0
