#!/usr/bin/env bash
#-------------------------------------------------------------------------------
# Copyright (C) 2026- Cursor Insight
#
# SPDX-License-Identifier: Apache-2.0
#-------------------------------------------------------------------------------
# Verify that the example project runs inside the expected Capsule workspace
# and setup.
#-------------------------------------------------------------------------------

set -euo pipefail

[[ "$(pwd -P)" == "/home/workspace" ]]
[[ "$(id -un)" == "user" ]]
[[ "${HOME:-}" == "/home/user" ]]
[[ "${USER:-}" == "user" ]]
[[ "${LOGNAME:-}" == "user" ]]

grep -Fxq 'capsule example fixture' fixture.txt

# Verify that Graphify and each bundled agent's vendor skill are available.
command -v graphify >/dev/null
graphify --version >/dev/null
[[ -f "$HOME/.claude/skills/graphify/SKILL.md" ]]
[[ -f "$HOME/.codex/skills/graphify/SKILL.md" ]]
[[ -f "$HOME/.gemini/config/skills/graphify/SKILL.md" ]]
[[ -f "$HOME/.claude/skills/maintain-graphify/SKILL.md" ]]
[[ -f "$HOME/.codex/skills/maintain-graphify/SKILL.md" ]]
[[ -f "$HOME/.gemini/config/skills/maintain-graphify/SKILL.md" ]]
[[ ! -e "$HOME/.claude/skills/maintain-graphify/agents" ]]
[[ -f "$HOME/.codex/skills/maintain-graphify/agents/openai.yaml" ]]
[[ ! -e "$HOME/.gemini/config/skills/maintain-graphify/agents" ]]

# The binary lives in the image and the skills in the persistent home volume,
# so they drift silently. Assert they agree, and that the image installed the
# committed pin rather than whatever upstream published most recently.
graphify_version="$(graphify --version | awk '{print $NF}')"
stamped_version="$(tr -d '[:space:]' </usr/local/share/graphify-version)"
[[ -n "$graphify_version" ]]
[[ "$graphify_version" == "$stamped_version" ]]

for skill_version in \
  "$HOME/.claude/skills/graphify/.graphify_version" \
  "$HOME/.codex/skills/graphify/.graphify_version" \
  "$HOME/.gemini/config/skills/graphify/.graphify_version"; do
  [[ -f "$skill_version" ]]
  [[ "$(tr -d '[:space:]' <"$skill_version")" == "$graphify_version" ]]
done

# The drift check must ship and stay advisory.
[[ -x /usr/local/bin/graphify-doctor.sh ]]
/usr/local/bin/graphify-doctor.sh /home/workspace >/dev/null 2>&1

printf 'capsule example ok\n'
