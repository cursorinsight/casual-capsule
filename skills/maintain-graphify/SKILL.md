---
name: maintain-graphify
description: >-
  Maintain Graphify knowledge graphs around non-trivial repository work. Use
  when graphify-out exists, architecture or impact analysis would benefit
  from a graph, structural edits need an incremental refresh, or the Capsule
  Graphify package and installed agent skills need updating.
---

# Maintain Graphify

Use Graphify's installed vendor skill as the source of truth for extraction
and query details. This skill adds lifecycle decisions that keep graphs useful
without silently changing repository integration.

## Start graph-aware work

1. Resolve the repository root and record `git status --short`.
2. Preserve unrelated worktree changes and existing `graphify-out/` data.
3. If `graphify-out/graph.json` exists, run
   `graphify reflect --if-stale`, read `graphify-out/reflections/LESSONS.md`
   when present, and query the graph before broad source inspection.
4. If no graph exists, build one only for architecture, impact analysis, or
   genuinely multi-file work. For a deterministic code-only bootstrap, run
   `graphify extract ROOT --code-only`.

Continue without Graphify when its CLI is unavailable. Report that graph
maintenance was skipped.

## Choose a focused query

- Use `graphify query` for broad context and neighboring concepts.
- Use `graphify explain` for one component or symbol.
- Use `graphify path` for a dependency or data-flow route.
- Use `graphify affected` before changing a shared interface.
- Use `graphify god-nodes` to identify central refactor risks.

Treat graph results as navigation evidence, then confirm consequential claims
in source. Do not invent missing nodes or edges.

## Refresh after changes

If a graph existed before the task, run `graphify update ROOT` after structural
code changes. Then run:

```bash
graphify diagnose multigraph --graph ROOT/graphify-out/graph.json
```

For documentation, configuration, images, or other semantic inputs, use the
vendor skill's incremental semantic-update flow. If that cannot complete,
preserve the current graph and its `graphify-out/needs_update` marker, then
report what remains stale.

For intentional deletion, try a normal update first. Use
`graphify update ROOT --force` only after confirming that every missing node
comes from files or symbols intentionally removed by the current task and no
extraction failure explains the shrinkage.

## Choose an LLM backend

Structural work needs no model: `graphify extract ROOT --code-only`,
`graphify update ROOT`, and every query command are deterministic. Only the
semantic pass and community labelling call an LLM.

When one is needed and no API key is set, route through the `claude` CLI that
Capsule already ships:

```bash
graphify cluster-only ROOT --backend claude-cli
```

It authenticates with the container's Claude subscription, so the work is
billed to that plan and no `ANTHROPIC_API_KEY` is required. Graphify never
selects this backend automatically, so pass `--backend claude-cli` on every
invocation that needs a model.

Set `GRAPHIFY_CLAUDE_CLI_MODEL`; the backend otherwise defaults to Opus,
which is oversized for structured extraction:

```bash
GRAPHIFY_CLAUDE_CLI_MODEL=haiku \
  graphify cluster-only ROOT --backend claude-cli
```

Each chunk runs as its own `claude -p` subprocess. Prefer an API backend for
a large first build and keep the CLI for incremental refreshes. The Codex CLI
has no equivalent backend.

## Keep integration changes explicit

Use `graphify watch ROOT` only for a controlled, long-running edit session and
stop it afterward. Run `graphify hook install` only when the user requests
persistent repository automation; it modifies Git hooks and `.gitattributes`.
Do not run project-scoped agent installers implicitly because they modify
tracked instruction or configuration files.

Graphify is image-managed inside Capsule. Do not upgrade it in a running
container. The installed release comes from the committed
`docker/graphify-version` pin, so `capsule --build` alone never moves it: run
`capsule --update-graphify` first, leave the rewritten pin for the user to
review, then rebuild. Use `GRAPHIFY_VERSION=X.Y.Z` when one build needs an
exact release without changing the pin.

## Finish

Report whether the graph was built, updated, unchanged, or left pending a
semantic refresh. Save a useful, dead-end, or corrected graph-assisted result
with `graphify save-result` when it will materially help a later session.
