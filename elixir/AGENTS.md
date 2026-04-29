# Symphony Elixir

Read [`../AGENTS.md`](../AGENTS.md) first. This file adds Elixir implementation rules for the
Entr'acte/Symphony service.

This directory contains the Elixir/OTP agent orchestration service that polls Linear, creates
per-issue workspaces, runs Codex in app-server mode, retries and reconciles active work, and exposes
terminal/Phoenix observability.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Main quality gate: `make all` (format check, lint, coverage, dialyzer).
- Keep setup reproducible from a fresh clone on another machine; update committed setup docs or
  scripts when adding a new prerequisite.

## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`../SPEC.md`](../SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Preserve portability across developer machines. Use `WORKFLOW.md`, env vars, and documented
  prerequisites for machine-local values instead of hard-coded absolute paths or host-specific
  assumptions.
- Workspace safety is critical and already has explicit containment checks:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Preserve local vs remote worker distinctions. Remote paths are validated differently from local
  canonical paths because remote filesystems are not locally inspectable.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve claims, retry/backoff,
  continuation, reconciliation, stall restart, worker-host capacity, and cleanup semantics.
- Codex app-server behavior is protocol-sensitive; preserve JSON-RPC line buffering, approval/input
  handling, dynamic tool responses, timeout behavior, and event forwarding.
- Token accounting must follow `docs/token_accounting.md`; do not treat generic `usage` maps as
  cumulative totals unless the event path proves that meaning.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Run targeted tests while iterating, then run full gates before handoff.

```bash
make all
```

Use narrower checks when they directly match the changed area:

- Config/workflow/workspace changes: `mix test test/symphony_elixir/workspace_and_config_test.exs`
- Orchestrator state/status changes: `mix test test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs`
- Codex app-server changes: `mix test test/symphony_elixir/app_server_test.exs`
- Dynamic Linear tool changes: `mix test test/symphony_elixir/dynamic_tool_test.exs`
- Dashboard rendering changes: `mix test test/symphony_elixir/status_dashboard_snapshot_test.exs`

Only run `make e2e` when explicitly needed; it uses real Linear resources and real Codex sessions.

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.
- Do not add new public APIs only for tests unless there is no cleaner boundary; existing
  `*_for_test` functions are deliberate seams and should stay explicit.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `../.github/pull_request_template.md` exactly.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `../README.md` for project concept and goals.
- `README.md` for Elixir implementation and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
- `docs/logging.md` for logging-context contract changes.
- `docs/token_accounting.md` for Codex usage/accounting changes.
