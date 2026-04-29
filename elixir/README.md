# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for explicitly ready candidate work (Linear is the current adapter)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves client-side tools for repo skills:
`linear_graphql` for raw Linear GraphQL calls and `gitlab_coverage` for normalized GitLab pipeline
coverage/status reads.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces. If the issue gets
the configured pause label, Symphony stops the active agent without treating the workspace as done.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
   If you want agents to inspect GitLab coverage, also set `GITLAB_API_TOKEN` and
   `GITLAB_PROJECT_ID`.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone <this-repo-url>
cd entracte/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
cp .env.example .env
$EDITOR .env
mise exec -- mix symphony.bootstrap
mix symphony.start
```

See [`docs/team_workflow.md`](docs/team_workflow.md) for team runner models, credit ownership, and
manager onboarding.

### Optional global launcher

Install a small `entracte` command into `~/.local/bin` when you want to start runners from profile
files without remembering the full Mix invocation:

```bash
mise exec -- mix entracte.install
```

Then use a TOML profile from any directory:

```bash
entracte /path/to/runner.toml
entracte check /path/to/runner.toml
```

Minimal profile:

```toml
[runner]
workflow = "WORKFLOW.md"
env_file = ".env"
logs_root = "log"
port = 4000
```

The profile path is resolved from the directory where `entracte` is invoked. Paths inside the
profile are resolved relative to the profile file, so a profile can live next to its own workflow and
env file.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--env-file` loads a local dotenv-style file before workflow config is resolved. If omitted,
  Symphony automatically loads `.env` next to the selected `WORKFLOW.md` when that file exists.
- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
dispatch:
  require_ready_label: true
  ready_label: agent-ready
  paused_label: agent-paused
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a tracked issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- The shipped `WORKFLOW.md` intentionally sets `codex.thread_sandbox: danger-full-access` and a
  `dangerFullAccess` turn policy because the default agent workflow must create branches, write Git
  metadata, push, and open PRs from the per-issue workspace. Use stricter sandbox settings only for
  workflows that do not need to publish Git work.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- `tracker.project_slug` can read from `LINEAR_PROJECT_SLUG` when unset or when value is
  `$LINEAR_PROJECT_SLUG`.
- `tracker.project_slugs` or `LINEAR_PROJECT_SLUGS` can configure several Linear projects for the
  same runner. Use comma-separated slugs in `.env`, such as
  `LINEAR_PROJECT_SLUGS=entracte-abc123,client-a-def456`.
- `tracker.assignee` can read from `LINEAR_ASSIGNEE` when unset or when value is `$LINEAR_ASSIGNEE`.
  Use `LINEAR_ASSIGNEE=me` for per-person runners, or leave it unset for a shared runner that should
  pick up all eligible issues.
- `dispatch.require_ready_label` defaults to `true`. With that default, assignment is ownership
  only; an issue must also have the configured ready label, `agent-ready`, before Symphony can spend
  Codex credits on it. The configured pause label, `agent-paused`, always wins and prevents new
  dispatches.
- The local `.env` file is ignored by git. Copy `.env.example` to `.env` and edit that file for
  workstation-specific values. Values loaded from `.env` apply to the current Symphony process before
  `WORKFLOW.md` config is resolved and override already-set process environment values for that run.
- Run `mix symphony.bootstrap` after adding `LINEAR_API_KEY` to `.env` or exporting it. It discovers
  projects visible to the configured tracker, writes the project slug when unambiguous, installs the
  dispatch labels, creates missing states listed in `tracker.bootstrap_states` such as
  `Human Review`, `Merging`, and `Rework`, installs the default tracker issue template, creates
  saved tracker views for `All`, `Ready`, `Paused`, plus each non-canceled Linear workflow state,
  favorites those views under a `Symphony` sidebar folder, and runs the smoke check.
  If several projects are visible, rerun it with `--project <slug>` or `--all-projects`.
- Run `mix symphony.check` after editing `.env` to verify the env file, workflow config, Linear
  read access, source repository reachability, and Codex binary before starting the daemon. The check
  does not create Linear issues or start Codex agents.
- Run `mix symphony.tracker_template.install` to create or update the default tracker issue template
  for each configured project team. `mix symphony.linear_template.install` remains as a
  Linear-specific compatibility command.
- Run `mix symphony.tracker_label.install` to create or update the dispatch labels without rerunning
  full bootstrap. The Linear adapter creates team-scoped `agent-ready` and `agent-paused` labels by
  default.
- Run `mix symphony.tracker_state.install` to create missing configured workflow states without
  rerunning full bootstrap. Existing team states are left unchanged.
- Run `mix symphony.tracker_view.install` to create or update the saved tracker views and sidebar
  favorites without rerunning full bootstrap. Use `--skip-favorites` to create the views without
  changing the authenticated Linear user's sidebar.
- Run `mix symphony.start` to start the runner with the guardrails acknowledgement and dashboard port
  handled for you. It defaults to `./WORKFLOW.md`, `.env`, and port `4000`, and creates missing
  tracker labels and issue templates before the runner starts. Use `--skip-label-install` or
  `--skip-template-install` to skip those checks.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

### Tracker Primitives

The orchestration runtime consumes provider-neutral tracker structs:

- `SymphonyElixir.Tracker.Issue` is the canonical work item passed to the orchestrator, workspace,
  prompt builder, and agent runner.
- `SymphonyElixir.Tracker.Project` and `SymphonyElixir.Tracker.IssueTemplate` describe provider
  discovery and setup concepts without baking Linear payloads into callers.
- `SymphonyElixir.Tracker.Label` and `SymphonyElixir.Tracker.LabelInstallation` describe setup for
  visible dispatch guardrail labels such as `agent-ready` and `agent-paused`.
- `SymphonyElixir.Tracker.TemplateInstallation` is the neutral result returned when an adapter
  creates, updates, or confirms an issue template.
- `SymphonyElixir.Tracker.View` and `SymphonyElixir.Tracker.ViewInstallation` describe saved tracker
  views and their setup results without leaking Linear custom view payloads into callers.
- Linear remains the shipped provider adapter today. `SymphonyElixir.Linear.Client` normalizes
  Linear GraphQL responses into `Tracker.Issue`, and `SymphonyElixir.Linear.Issue` is kept only as
  a compatibility helper.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
gitlab:
  endpoint: $GITLAB_API_ENDPOINT
  api_token: $GITLAB_API_TOKEN
  project_id: $GITLAB_PROJECT_ID
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    : "${SOURCE_REPO_URL:?Set SOURCE_REPO_URL}"
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "${CODEX_BIN:-codex} --config 'model=\"gpt-5.5\"' app-server"
```

### Multiple Projects

One runner can watch several Linear projects when they share the same repository, workflow, Codex
account, workspace root, and machine. Put all project slugs in `.env`:

```env
LINEAR_PROJECT_SLUGS=entracte-abc123,client-a-def456
```

The runner polls those projects in the same refresh cycle and deduplicates issues by Linear issue
ID before dispatching agents.

Use separate ignored env profiles only when projects need isolation, such as different source
repositories, workflows, Codex accounts, workspace roots, ports, or logs:

```bash
cp .env.example .env.entracte
cp .env.example .env.client-a
```

Set different values in each file. To start one profile explicitly:

```bash
mix symphony.start --profile entracte
```

To start all profiles with one command, define the list in `.env`:

```env
SYMPHONY_PROFILES=entracte,client-a
```

Then run:

```bash
mix symphony.start
```

The launcher starts one OS process per profile because the Symphony app itself has singleton runtime
state. Each child loads `.env.<profile>`, defaults logs to `log/<profile>`, and writes process output
to `log/<profile>/process.log`. Set a distinct `SYMPHONY_PORT` in each profile if you want separate
web dashboards.

Profile-aware checks and template installation also work:

```bash
mix symphony.bootstrap --profile entracte --project entracte-abc123
mix symphony.check --profile entracte
mix symphony.tracker_template.install --profile entracte
mix symphony.tracker_view.install --profile entracte
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end tests only when you want Symphony to create disposable Linear
resources and, for the agent-flow scenarios, launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs three live scenarios:
- one full agent flow with a local worker
- one full agent flow with SSH workers
- one orchestrator guardrail flow that verifies a real Linear issue stays idle until `agent-ready`
  and stops when `agent-paused` is added

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The full agent live tests create a temporary Linear project and issue, write a temporary
`WORKFLOW.md`, run a real agent turn, verify the workspace side effect, require Codex to comment on
and close the Linear issue, then mark the project completed so the run remains visible in Linear.
The guardrail live test uses a blocking `before_run` hook instead of spending a Codex turn, then
asserts the orchestrator dispatch/stop behavior against the real Linear API.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
