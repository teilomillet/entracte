# Team Workflow

Symphony uses Linear as the team-facing control plane and a runner machine as the execution plane.
The team writes and reviews work in Linear and GitHub; the machine running Symphony pays for and
executes Codex turns.
This guide describes the current Linear-backed setup; internally, Symphony normalizes tracker data
into provider-neutral primitives so another tracker adapter can be added without changing runner
orchestration.

## Mental Model

- Linear is the entrypoint. Create issues, move statuses, assign owners, and review the persistent
  `## Codex Workpad` comment there.
- The runner is the computer that executes work. It polls Linear, creates per-issue workspaces,
  starts Codex app-server sessions, and pushes PRs through the credentials available on that machine.
- Codex credits are charged to the Codex account authenticated on the runner, not to the Linear user
  who created the ticket.
- Linear API usage is separate from Codex usage. `LINEAR_API_KEY` controls tracker access; Codex auth
  controls model usage.

## Runner Models

### Shared Team Runner

Use one always-on machine or VM for the team.

- Best when the team wants one operational dashboard and one billing owner.
- The runner uses a shared/service Codex account and a Linear token with access to the target project.
- Everyone interacts through Linear; the runner picks up eligible issues.
- Set `LINEAR_ASSIGNEE` empty if the runner should pick up all eligible issues, or set it to a
  specific Linear user ID/email if the runner should only pick up work assigned to that identity.

### Per-Person Runner

Each engineer runs Symphony locally.

- Best when each engineer should use their own Codex credits and local credentials.
- Set `LINEAR_ASSIGNEE=me` so each runner only handles issues assigned to its authenticated Linear
  user.
- Each engineer needs local Codex auth, GitHub auth, and access to the source repo.

### Hybrid

Run a shared runner for default work and allow engineers to run local runners for selected issues.

- Use Linear assignment to avoid two runners claiming the same work.
- Keep `agent.max_concurrent_agents` conservative at first until the team understands review and
  credit usage patterns.

## Required Linear Setup

The default workflow expects these statuses:

- `Backlog`
- `Todo`
- `In Progress`
- `Human Review`
- `Merging`
- `Rework`
- terminal states such as `Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`

The daemon dispatches issues in configured active states. The prompt tells the agent how to route
each state and when to move work to `Human Review` or use the `land` flow.

The default workflow also expects two visible guardrail labels:

- `agent-ready`: explicit permission for a runner to spend Codex credits on the issue.
- `agent-paused`: hard stop. It blocks new dispatch and stops an already running agent on the next
  reconciliation tick.

Assignment is ownership, not execution permission. With the default config, an assigned issue can sit
in a runner's backlog safely until someone adds `agent-ready`.

## Environment

Use a local `.env` file for machine-local values so the same repo works on another machine:

```bash
cd elixir
cp .env.example .env
$EDITOR .env
```

The `.env` file is ignored by git. It is loaded automatically when it sits next to `WORKFLOW.md`, or
it can be passed explicitly with `--env-file /path/to/runner.env`. Values from the env file override
already-set process environment values for that runner process.

`LINEAR_ASSIGNEE` may be unset for a shared runner that should pick up all eligible issues.
`SOURCE_REPO_URL` can be SSH or HTTPS, but it must match the auth available on the runner.

Run a non-destructive smoke check before starting a runner:

```bash
mise exec -- mix symphony.check
```

The check validates local config, Linear read access, source repository reachability, and the Codex
binary. It does not create Linear issues or start Codex agents.

For first-time setup, use the bootstrap command after adding `LINEAR_API_KEY` to `.env` or exporting
it in the shell:

```bash
mise exec -- mix symphony.bootstrap
```

Bootstrap discovers projects visible to the configured tracker, writes the project slug when there
is only one match, installs the dispatch labels, creates missing states listed in
`tracker.bootstrap_states`, installs the default issue template, creates saved views for `All`,
`Ready`, `Paused`, plus each non-canceled Linear workflow state, adds those views to a `Symphony`
sidebar folder for the authenticated Linear user, and runs the smoke check. If several projects are
visible, rerun with `--project <slug>` or `--all-projects`.

Install or repair just the dispatch labels without rerunning full bootstrap:

```bash
mise exec -- mix symphony.tracker_label.install
```

Install missing workflow states without rerunning full bootstrap:

```bash
mise exec -- mix symphony.tracker_state.install
```

The Linear adapter only creates missing states; it does not rewrite existing team workflow states.

Install the default tracker issue template for the configured project team or teams:

```bash
mise exec -- mix symphony.tracker_template.install
```

The command is idempotent: it creates `Codex Agent Task` when missing and updates the existing
template with the same name when present. The Linear adapter maps this to team-scoped Linear issue
templates, so several projects on the same Linear team share one template.

Install the saved tracker views without rerunning full bootstrap:

```bash
mise exec -- mix symphony.tracker_view.install
```

The Linear adapter maps this to shared custom views named `Symphony: <project> / <state>` and
sidebar favorites under a `Symphony` folder, including `Ready` and `Paused` views for the guardrail
labels. Use `--skip-favorites` when you only want to create the shared views and leave the current
user's Linear sidebar unchanged.

## Start A Runner

```bash
cd elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mix symphony.start
```

`mix symphony.start` creates missing tracker labels and issue templates before the runner starts. Use
`mix symphony.tracker_label.install` or `mix symphony.tracker_template.install` when you want to
force-update setup without starting the runner.

Open `http://127.0.0.1:4000` on the runner machine to watch active work.

## Operating Rules

- Treat Linear issue assignment as runner ownership when multiple people run Symphony.
- Treat `agent-ready` as execution permission. Add it only when the issue should enter that runner's
  queue.
- Treat `agent-paused` as an intentional override. Use it when an issue should not start or should
  stop even if it is assigned and otherwise active.
- Treat each issue as a task contract before adding `agent-ready`: desired outcome, current
  evidence/signal, scope boundaries, acceptance criteria, validation, and unknowns should be visible
  enough that the runner can execute without guessing.
- Start with low concurrency, then raise `agent.max_concurrent_agents` after the team has observed
  review load and credit usage.
- Keep acceptance criteria and validation requirements in the Linear issue. The workflow prompt tells
  the agent to mirror them into the workpad and execute them.
- Keep branch history linear. The workflow syncs branches by rebase or fast-forward before handoff
  and before merge; it should not merge `origin/main` into task branches.
- A human should review PRs before moving issues to `Merging`.
- The runner's dashboard and logs show token totals for the daemon, but spend attribution is by
  runner/Codex account. If per-person chargeback matters, use per-person runners or separate service
  accounts per runner.
- One Symphony runner can watch several Linear projects with `LINEAR_PROJECT_SLUGS` when those
  projects share the same repo, workflow, Codex account, workspace root, and runner machine. Use
  separate ignored env profiles only when those values need to differ. If `.env` defines
  `SYMPHONY_PROFILES=entracte,client-a`, `mix symphony.start` launches each `.env.<profile>` as a
  separate OS process and writes process output to `log/<profile>/process.log`.

## Manager Onboarding Checklist

1. Install `mise`, Elixir/Erlang via `mise install`, GitHub auth, and Codex auth.
2. Create or obtain a Linear personal API key.
3. Copy `.env.example` to `.env` and fill in the runner values.
4. Run `mise exec -- mix setup`, `mise exec -- mix build`, and `mise exec -- mix symphony.bootstrap`.
   For profile-based setups, run `mise exec -- mix symphony.bootstrap --profile <name> --project <slug>`
   for each profile.
5. Start the runner with `mix symphony.start`.
6. Create a small Linear test issue in `Todo`, assign it according to the runner model, add
   `agent-ready`, and watch the workpad/dashboard before enabling more concurrency.
