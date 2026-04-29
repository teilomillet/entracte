# AGENTS.md

This repository is Entr'acte's Symphony-derived agent orchestration service.
The code still uses the `Symphony` and `SymphonyElixir` names in docs, modules, binaries, and
runtime contracts. Do not rename those identifiers unless the task explicitly asks for a rename.

The service is a long-running orchestrator for coding-agent work: it loads `WORKFLOW.md`, polls a
tracker, creates isolated per-issue workspaces, runs Codex app-server sessions, reconciles issue
state, retries failures, and exposes operator-visible status. Treat it as infrastructure code where
small misunderstandings can produce runaway agents, lost workspaces, bad ticket state, or misleading
observability.

## Core Working Rules

1. Justify decisions explicitly.
   Every meaningful design or implementation choice should include a short reason. If there are
   competing options, state the tradeoff and why the chosen path fits this codebase.

2. Do not assume; verify.
   Before making claims about behavior, architecture, tests, or runtime contracts, inspect the local
   code and relevant docs. Distinguish verified facts from hypotheses, and say what would verify any
   remaining uncertainty.

3. Reproduce or identify the signal first.
   For bugs, regressions, and operational issues, capture the current failure signal before changing
   code when practical. For protocol/config changes, identify the exact code path and tests that
   prove the contract.

4. Keep changes narrowly scoped.
   Avoid unrelated refactors. This repo has stateful orchestration, external APIs, subprocesses,
   remote SSH workers, and filesystem cleanup; broad edits raise risk quickly.

5. Preserve operability.
   Logging, dashboard snapshots, retry state, and cleanup semantics are part of the product. Do not
   treat them as incidental while changing orchestration behavior.

6. Keep the project portable.
   Changes should work after a fresh clone on another development machine. Avoid machine-specific
   absolute paths, unchecked local services, untracked generated files, or setup steps that only work
   on this laptop.

## Codebase Contracts

- Keep implementation behavior aligned with [`SPEC.md`](SPEC.md). The implementation may be a
  documented superset, but it must not conflict with the spec.
- Runtime behavior is loaded from `WORKFLOW.md` front matter and routed through
  `SymphonyElixir.Workflow`, `SymphonyElixir.WorkflowStore`, `SymphonyElixir.Config`, and
  `SymphonyElixir.Config.Schema`. Prefer typed config access there over ad-hoc env reads.
- `SymphonyElixir.Orchestrator` owns claims, running state, retry/backoff state, issue
  reconciliation, worker-host capacity, stall restarts, and dashboard snapshots. Changes here need
  focused tests because they are concurrency-sensitive.
- `SymphonyElixir.Workspace` and `SymphonyElixir.Codex.AppServer` enforce workspace-root safety.
  Never weaken the rule that Codex turns run inside per-issue workspaces, not in the source repo.
- Local paths must be canonicalized when safety depends on containment. Be explicit about symlink
  behavior and remote-worker differences.
- Tracker access goes through `SymphonyElixir.Tracker` and its adapters. Keep Linear payload
  normalization in the Linear client/adapter boundary.
- Codex app-server handling is a JSON-RPC stream over stdio or SSH. Preserve partial-line buffering,
  timeout behavior, non-interactive input handling, dynamic tool replies, and protocol event
  reporting when changing it.
- Token accounting semantics are documented in `elixir/docs/token_accounting.md`; do not reinterpret
  generic `usage` payloads without checking event type and payload path.
- Logging conventions are documented in `elixir/docs/logging.md`. Issue-related logs need
  `issue_id` and `issue_identifier`; Codex lifecycle logs need `session_id` when available.

## Portability

- Prefer repository-relative paths in docs, scripts, tests, and examples. Use env vars or
  `WORKFLOW.md` config for machine-local values such as workspace roots, tokens, SSH config, and
  source clone URLs.
- Keep dependency and tool versions pinned through committed project files such as `mix.lock` and
  `elixir/mise.toml`. Do not rely on globally installed packages beyond documented prerequisites.
- Any generated artifact needed to build or test on another machine must either be committed or
  produced by a documented command. Do not depend on files that happen to exist in a local cache.
- Build and validation commands should be reproducible from a clean checkout. If a command requires
  credentials, network access, Linear state, Codex auth, SSH hosts, or other external resources,
  document those requirements and keep the default path safe for local development.
- Test fixtures should not depend on user-specific home directories, hostnames, ports, or credentials
  unless the test explicitly injects them.

## Code Organization

- Prefer small, focused modules and named helpers. Existing large modules such as the orchestrator,
  app-server client, and dashboard are already dense; avoid making them denser without a clear
  reason.
- Keep orchestration separate from config parsing, tracker integration, workspace lifecycle, Codex
  protocol handling, SSH transport, and presentation.
- Add abstractions only when they remove real duplication or clarify a boundary already present in
  the code.
- Public functions in `elixir/lib/` need adjacent `@spec` declarations unless they are `@impl`
  callback implementations. This is enforced by `mix specs.check`.

## Validation

Work under `elixir/` for Elixir commands.

- Targeted iteration: run the smallest `mix test ...` command that covers the changed behavior.
- Spec gate: `mix specs.check`.
- Full local gate before handoff when practical: `make all`.
- Live external E2E is opt-in only: `make e2e` requires Linear credentials and launches real Codex
  sessions. Do not run it casually.

For behavior/config changes, update the relevant docs in the same change when practical:

- `README.md` for project concept and goals.
- `elixir/README.md` for implementation and run instructions.
- `SPEC.md` for language-agnostic service contract changes.
- `elixir/WORKFLOW.md` for workflow/config contract changes.
- `elixir/docs/*` for logging, token accounting, or operational semantics.

## Communication

When working in this repository:

- Explain what you are checking before large edits.
- Cite files, tests, logs, or command output for factual claims.
- Label assumptions and open questions clearly.
- Report validation results precisely, including commands not run and why.

## What To Avoid

- Architecture claims without reading the code.
- Spec or config changes without corresponding tests/docs.
- Workspace cleanup or sandbox changes without path-safety tests.
- Orchestrator changes that skip retry, reconciliation, stall, or terminal-state cases.
- Logging large payloads or secrets.
- Silent fallbacks that make operations or debugging ambiguous.
