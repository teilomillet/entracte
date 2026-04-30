defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias Phoenix.LiveView.JS
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Tokens by project</h2>
              <p class="section-copy">Aggregate Codex token usage grouped by tracker project.</p>
            </div>
          </div>

          <%= if project_totals(@payload) == [] do %>
            <p class="empty-state">No project token usage recorded yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Total</th>
                    <th>Input</th>
                    <th>Output</th>
                    <th>Runtime</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- project_totals(@payload)}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= project_name(entry.project) %></span>
                        <%= if project_slug(entry.project) do %>
                          <span class="muted"><%= project_slug(entry.project) %></span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_int(entry.total_tokens) %></td>
                    <td class="numeric"><%= format_int(entry.input_tokens) %></td>
                    <td class="numeric"><%= format_int(entry.output_tokens) %></td>
                    <td class="numeric"><%= format_runtime_seconds(entry.seconds_running) %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card activity-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">What's happening</h2>
              <p class="section-copy">Active issue focus, milestones, and diagnostics.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="issue-activity-grid">
              <article :for={entry <- @payload.running} class="issue-activity-card">
                <header class="issue-activity-header">
                  <div class="issue-heading">
                    <a class="issue-id issue-id-link" href={"/api/v1/#{entry.issue_identifier}"}>
                      <%= entry.issue_identifier %>
                    </a>
                    <span class={state_badge_class(entry.state)}>
                      <%= entry.state %>
                    </span>
                  </div>

                  <%= if entry.session_id do %>
                    <button
                      type="button"
                      class="subtle-button"
                      data-label="Copy ID"
                      data-copy={entry.session_id}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy ID
                    </button>
                  <% end %>
                </header>

                <div class="focus-panel">
                  <span class={focus_badge_class(entry.current_focus.kind)}>
                    <%= entry.current_focus.label %>
                  </span>
                  <div class="focus-copy">
                    <p class="focus-detail">
                      <%= focus_detail(entry.current_focus) %>
                    </p>
                    <p class="focus-meta numeric">
                      <span><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></span>
                      <span><%= format_int(entry.tokens.total_tokens) %> tokens</span>
                      <span><%= format_time(entry.current_focus.at || entry.last_event_at) %></span>
                    </p>
                  </div>
                </div>

                <%= if entry.workspace_git && entry.workspace_git.available do %>
                  <div class="workstate-panel">
                    <div class="workstate-header">
                      <div class="workstate-main">
                        <p class="workstate-kicker">Working copy</p>
                        <p class="workstate-title">
                          <%= entry.workspace_git.branch_label %>
                        </p>
                        <p class="workstate-detail">
                          <%= git_head_summary(entry.workspace_git) %>
                        </p>
                      </div>
                      <div class="workstate-badges">
                        <span class={workstate_badge_class(entry.workspace_git)}>
                          <%= workstate_stage(entry.workspace_git) %>
                        </span>
                        <span class="workstate-chip"><%= git_relation(entry.workspace_git) %></span>
                        <span class="workstate-chip"><%= published_label(entry.workspace_git) %></span>
                      </div>
                    </div>

                    <div class="workstate-grid">
                      <div>
                        <p class="workstate-subtitle">Branch changes</p>
                        <%= if entry.workspace_git.branch_diff.changed_count in [0, nil] do %>
                          <p class="workstate-empty">No committed branch diff from origin/main.</p>
                        <% else %>
                          <ul class="workstate-file-list">
                            <li :for={file <- entry.workspace_git.branch_diff.files} class="workstate-file">
                              <span class={file_status_class(file.kind)}><%= file.status %></span>
                              <span class="workstate-file-path"><%= file.path %></span>
                            </li>
                          </ul>
                          <%= if entry.workspace_git.branch_diff.hidden_count > 0 do %>
                            <p class="workstate-more">
                              +<%= entry.workspace_git.branch_diff.hidden_count %> more files
                            </p>
                          <% end %>
                        <% end %>
                      </div>

                      <div>
                        <p class="workstate-subtitle">Uncommitted files</p>
                        <%= if entry.workspace_git.working_tree.clean do %>
                          <p class="workstate-empty">Working tree clean.</p>
                        <% else %>
                          <ul class="workstate-file-list">
                            <li :for={file <- entry.workspace_git.working_tree.files} class="workstate-file">
                              <span class={file_status_class(file.kind)}><%= file.status %></span>
                              <span class="workstate-file-path"><%= file.path %></span>
                            </li>
                          </ul>
                          <%= if entry.workspace_git.working_tree.hidden_count > 0 do %>
                            <p class="workstate-more">
                              +<%= entry.workspace_git.working_tree.hidden_count %> more files
                            </p>
                          <% end %>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <div class="workstate-panel workstate-panel-muted">
                    <p class="workstate-empty">
                      Workspace state unavailable: <%= entry.workspace_git && entry.workspace_git.reason || "unknown" %>
                    </p>
                  </div>
                <% end %>

                <%= if entry.milestones == [] do %>
                  <p class="empty-state compact-empty">No meaningful milestone yet.</p>
                <% else %>
                  <ol class="milestone-list">
                    <li :for={milestone <- entry.milestones} class="milestone-item">
                      <span class={milestone_dot_class(milestone.kind)}></span>
                      <div class="milestone-copy">
                        <p class="milestone-title"><%= milestone.label %></p>
                        <%= if milestone.detail do %>
                          <p class="milestone-detail"><%= milestone.detail %></p>
                        <% end %>
                      </div>
                      <time class="milestone-time numeric"><%= format_time(milestone.at) %></time>
                    </li>
                  </ol>
                <% end %>

                <details class="diagnostics-panel" phx-mounted={JS.ignore_attributes(["open"])}>
                  <summary>
                    Diagnostics
                    <span class="diagnostics-count">
                      <%= diagnostic_count(entry.diagnostics) %>
                    </span>
                  </summary>
                  <ol class="diagnostic-list">
                    <li :for={event <- entry.diagnostics.events} class="diagnostic-item">
                      <span class="diagnostic-time numeric"><%= format_time(event.at) %></span>
                      <span class="diagnostic-message">
                        <%= event.message || to_string(event.event || "n/a") %>
                      </span>
                    </li>
                  </ol>
                </details>

                <details class="console-panel" phx-mounted={JS.ignore_attributes(["open"])}>
                  <summary>
                    Console
                    <span class="diagnostics-count">
                      <%= length(entry.recent_events) %>
                    </span>
                  </summary>
                  <div class="console-scroll" role="log" aria-label={"#{entry.issue_identifier} event console"}>
                    <ol class="console-list">
                      <li :for={event <- console_events(entry.recent_events)} class={console_event_class(event)}>
                        <span class="console-time numeric"><%= format_time(event.at) %></span>
                        <span class="console-event"><%= event.event || "event" %></span>
                        <span class="console-message">
                          <%= event.message || to_string(event.event || "n/a") %>
                        </span>
                      </li>
                    </ol>
                  </div>
                </details>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card activity-section">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent event stream</h2>
              <p class="section-copy">Raw recent events, kept for debugging.</p>
            </div>
          </div>

          <%= if @payload.activity == [] do %>
            <p class="empty-state">No Codex activity has been recorded yet.</p>
          <% else %>
            <details class="raw-activity-panel" phx-mounted={JS.ignore_attributes(["open"])}>
              <summary>Show raw events</summary>
              <ol class="activity-list">
                <li :for={entry <- @payload.activity} class="activity-item">
                  <div class="activity-main">
                    <div class="activity-heading">
                      <span class="issue-id"><%= entry.issue_identifier %></span>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                    </span>
                    </div>
                    <p class="activity-message">
                      <%= entry.message || to_string(entry.event || "n/a") %>
                    </p>
                  </div>
                  <div class="activity-meta">
                    <span class="mono numeric"><%= format_time(entry.at) %></span>
                  </div>
                </li>
              </ol>
            </details>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp project_totals(payload) do
    Map.get(payload, :codex_project_totals, []) || []
  end

  defp project_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_name(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_name(_project), do: "Unknown project"

  defp project_slug(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_slug(_project), do: nil

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp focus_badge_class(kind), do: "focus-badge focus-badge-#{css_token(kind)}"
  defp milestone_dot_class(kind), do: "milestone-dot milestone-dot-#{css_token(kind)}"
  defp file_status_class(kind), do: "file-status file-status-#{css_token(kind)}"

  defp css_token(kind) do
    kind
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
  end

  defp focus_detail(%{detail: detail}) when is_binary(detail) and detail != "", do: detail
  defp focus_detail(%{label: label}) when is_binary(label), do: label
  defp focus_detail(_focus), do: "Waiting for activity"

  defp workstate_stage(%{rebasing: true}), do: "Rebasing"

  defp workstate_stage(%{working_tree: %{conflict_count: count}}) when is_integer(count) and count > 0,
    do: "Conflict"

  defp workstate_stage(%{working_tree: %{changed_count: count}}) when is_integer(count) and count > 0,
    do: "Editing"

  defp workstate_stage(%{relation: %{ahead: ahead}, published: %{published: true}}) when is_integer(ahead) and ahead > 0,
    do: "Pushed"

  defp workstate_stage(%{relation: %{ahead: ahead}}) when is_integer(ahead) and ahead > 0,
    do: "Local commit"

  defp workstate_stage(%{relation: %{behind: behind}}) when is_integer(behind) and behind > 0,
    do: "Behind main"

  defp workstate_stage(_git), do: "Synced"

  defp workstate_badge_class(%{working_tree: %{conflict_count: count}}) when is_integer(count) and count > 0,
    do: "workstate-badge workstate-badge-danger"

  defp workstate_badge_class(%{rebasing: true}), do: "workstate-badge workstate-badge-warning"

  defp workstate_badge_class(%{working_tree: %{changed_count: count}}) when is_integer(count) and count > 0,
    do: "workstate-badge workstate-badge-warning"

  defp workstate_badge_class(_git), do: "workstate-badge"

  defp git_head_summary(%{head: %{short_sha: short_sha, subject: subject}, base: %{short_sha: base_sha}}) do
    head = [short_sha, subject] |> Enum.reject(&blank?/1) |> Enum.join(" ")
    base = if blank?(base_sha), do: "base n/a", else: "base #{base_sha}"

    [head, base]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp git_head_summary(_git), do: "No git summary available"

  defp git_relation(%{relation: %{ahead: ahead, behind: behind}}) when is_integer(ahead) and is_integer(behind) do
    cond do
      ahead > 0 and behind > 0 -> "+#{ahead} / -#{behind}"
      ahead > 0 -> "+#{ahead}"
      behind > 0 -> "-#{behind}"
      true -> "even"
    end
  end

  defp git_relation(_git), do: "unknown"

  defp published_label(%{published: %{published: true}}), do: "pushed"
  defp published_label(%{published: %{has_remote_branch: true}}), do: "unpushed head"
  defp published_label(_git), do: "not pushed"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp diagnostic_count(%{events: events, hidden_count: hidden_count}) when is_list(events) do
    visible_count = length(events)

    case hidden_count do
      count when is_integer(count) and count > 0 -> "#{visible_count}+#{count}"
      _ -> Integer.to_string(visible_count)
    end
  end

  defp diagnostic_count(_diagnostics), do: "0"

  defp console_events(events) when is_list(events), do: Enum.reverse(events)
  defp console_events(_events), do: []

  defp console_event_class(%{event: event, message: message}) do
    base = "console-item"
    text = "#{event} #{message}" |> String.downcase()

    cond do
      String.contains?(text, ["failed", "error", "blocked", "approval_required"]) -> "#{base} console-item-danger"
      String.contains?(text, ["completed", "success", "human review"]) -> "#{base} console-item-success"
      String.contains?(text, ["started", "requested", "running", "inprogress"]) -> "#{base} console-item-active"
      true -> base
    end
  end

  defp console_event_class(_event), do: "console-item"

  defp format_time(nil), do: "n/a"

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%H:%M:%SZ")
  end

  defp format_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> format_time(datetime)
      _ -> value
    end
  end

  defp format_time(_value), do: "n/a"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
