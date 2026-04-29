defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @milestone_limit 4
  @diagnostic_limit 8
  @changed_files_limit 8
  @milestone_rules [
    {:command_failed, "danger", "Command failed", :raw},
    {:files_changed, "edit", "Updated files", :raw},
    {:linear_graphql, "tracker", "Reading Linear", :none},
    {:dynamic_tool, "tool", "Calling tool", :raw},
    {:web_search, "research", "Checking external docs", :none},
    {:github_auth, "git", "Checked GitHub auth", :compact},
    {:pr_checks, "review", "Watching PR checks", :compact},
    {:sourcery_review, "review", "Reading PR review", :compact},
    {:tests, "test", "Running tests", :compact},
    {:compile, "build", "Compiling project", :compact},
    {:human_review, "review", "Preparing human review", :compact},
    {:pull_request, "pr", "Working on PR", :compact}
  ]

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          activity: activity_payload(snapshot.running),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    activity = running_activity_payload(entry)
    workspace_path = Map.get(entry, :workspace_path)

    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: workspace_path,
      workspace_git: workspace_git_payload(workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      recent_events: recent_events_payload(entry),
      current_focus: activity.current_focus,
      milestones: activity.milestones,
      diagnostics: activity.diagnostics,
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    activity = running_activity_payload(running)
    workspace_path = Map.get(running, :workspace_path)

    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: workspace_path,
      workspace_git: workspace_git_payload(workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      recent_events: recent_events_payload(running),
      current_focus: activity.current_focus,
      milestones: activity.milestones,
      diagnostics: activity.diagnostics,
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp activity_payload(running_entries) when is_list(running_entries) do
    running_entries
    |> Enum.flat_map(&activity_entries_for_running_entry/1)
    |> Enum.sort_by(&activity_sort_key/1, :desc)
    |> Enum.take(10)
  end

  defp activity_payload(_running_entries), do: []

  defp activity_entries_for_running_entry(running) when is_map(running) do
    running
    |> recent_events_payload()
    |> Enum.map(fn event ->
      Map.merge(event, %{
        issue_id: running.issue_id,
        issue_identifier: running.identifier,
        state: running.state,
        session_id: running.session_id
      })
    end)
  end

  defp activity_entries_for_running_entry(_running), do: []

  defp activity_sort_key(%{at: at}) when is_binary(at), do: at
  defp activity_sort_key(_activity), do: ""

  defp running_activity_payload(running) when is_map(running) do
    events = recent_events_payload(running)
    milestones = milestone_payload(events)

    %{
      current_focus: current_focus_payload(events, milestones, running),
      milestones: milestones,
      diagnostics: diagnostic_payload(events)
    }
  end

  defp milestone_payload(events) do
    events
    |> Enum.map(&milestone_from_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&milestone_key/1)
    |> Enum.take(@milestone_limit)
  end

  defp milestone_key(%{kind: kind, label: label, detail: detail}) do
    {kind, label, normalize_message(detail)}
  end

  defp diagnostic_payload(events) do
    event_count = length(events)
    events = Enum.take(events, @diagnostic_limit)

    %{
      events: events,
      hidden_count: max(event_count - @diagnostic_limit, 0)
    }
  end

  defp current_focus_payload(_events, [milestone | _rest], _running) do
    %{
      label: milestone.label,
      detail: milestone.detail,
      at: milestone.at,
      kind: milestone.kind
    }
  end

  defp current_focus_payload(events, _milestones, running) do
    events
    |> Enum.find_value(&fallback_focus_from_event/1)
    |> case do
      nil ->
        %{
          label: "Waiting for activity",
          detail: summarize_message(Map.get(running, :last_codex_message)),
          at: iso8601(Map.get(running, :last_codex_timestamp)),
          kind: "idle"
        }

      focus ->
        focus
    end
  end

  defp milestone_from_event(%{message: message} = event) do
    normalized = normalize_message(message)

    if normalized == "" or noisy_message?(normalized) do
      nil
    else
      Enum.find_value(@milestone_rules, &milestone_for_rule(&1, event, normalized, message))
    end
  end

  defp milestone_from_event(_event), do: nil

  defp milestone_for_rule({rule, kind, label, detail_mode}, event, normalized, message) do
    if milestone_rule_matches?(rule, normalized) do
      milestone(event, kind, label, milestone_detail(detail_mode, message))
    end
  end

  defp milestone_rule_matches?(:command_failed, message),
    do: String.contains?(message, "command execution") and String.contains?(message, "failed")

  defp milestone_rule_matches?(:files_changed, message), do: String.contains?(message, "turn diff updated")

  defp milestone_rule_matches?(:linear_graphql, message),
    do: String.contains?(message, "dynamic tool call requested (linear_graphql)")

  defp milestone_rule_matches?(:dynamic_tool, message), do: String.contains?(message, "dynamic tool call requested")
  defp milestone_rule_matches?(:web_search, message), do: String.contains?(message, "item started: web search")

  defp milestone_rule_matches?(:github_auth, message),
    do: String.contains?(message, "github.com") and String.contains?(message, "logged in")

  defp milestone_rule_matches?(:pr_checks, message), do: String.contains?(message, "refreshing checks status")
  defp milestone_rule_matches?(:sourcery_review, message), do: String.contains?(message, "sourcery")

  defp milestone_rule_matches?(:tests, message),
    do: String.contains?(message, "cover compiling") or String.contains?(message, "running exunit")

  defp milestone_rule_matches?(:compile, message), do: String.contains?(message, "compiling")
  defp milestone_rule_matches?(:human_review, message), do: String.contains?(message, "human review")

  defp milestone_rule_matches?(:pull_request, message),
    do: String.contains?(message, "pull request") or String.contains?(message, " pr ")

  defp milestone_rule_matches?(_rule, _message), do: false

  defp milestone_detail(:none, _message), do: nil
  defp milestone_detail(:compact, message), do: compact_detail(message)
  defp milestone_detail(:raw, message), do: message

  defp milestone(%{at: at, event: event}, kind, label, detail) do
    %{at: at, event: event, kind: kind, label: label, detail: detail}
  end

  defp fallback_focus_from_event(%{message: message} = event) do
    normalized = normalize_message(message)

    cond do
      normalized == "" ->
        nil

      String.contains?(normalized, "item started: reasoning") ->
        focus(event, "reasoning", "Reasoning", nil)

      String.contains?(normalized, "item started: command execution") ->
        focus(event, "command", "Running command", nil)

      String.contains?(normalized, "command output streaming") and not noisy_message?(normalized) ->
        focus(event, "command", "Reading command output", compact_detail(message))

      String.contains?(normalized, "item started: agent message") ->
        focus(event, "message", "Writing update", nil)

      true ->
        focus(event, "activity", "Active", compact_detail(message))
    end
  end

  defp fallback_focus_from_event(_event), do: nil

  defp focus(%{at: at}, kind, label, detail), do: %{at: at, kind: kind, label: label, detail: detail}

  defp noisy_message?(message) when is_binary(message) do
    String.starts_with?(message, [
      "thread token usage updated",
      "rate limits updated",
      "item completed: reasoning",
      "item started: reasoning",
      "item completed: command execution",
      "item started: command execution",
      "item completed: agent message",
      "item started: agent message",
      "agent message streaming:",
      "command output streaming: ."
    ])
  end

  defp compact_detail(nil), do: nil

  defp compact_detail(message) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_message(nil), do: ""
  defp normalize_message(message), do: message |> to_string() |> String.downcase() |> String.trim()

  defp recent_events_payload(running) do
    case Map.get(running, :codex_recent_events, []) do
      events when is_list(events) and events != [] ->
        events
        |> Enum.map(&recent_event_payload/1)
        |> Enum.reject(&is_nil(&1.at))

      _ ->
        [
          %{
            at: iso8601(running.last_codex_timestamp),
            event: running.last_codex_event,
            message: summarize_message(running.last_codex_message)
          }
        ]
        |> Enum.reject(&is_nil(&1.at))
    end
  end

  defp recent_event_payload(event) when is_map(event) do
    %{
      at: iso8601(Map.get(event, :timestamp) || Map.get(event, "timestamp")),
      event: Map.get(event, :event) || Map.get(event, "event"),
      message: summarize_message(Map.get(event, :message) || Map.get(event, "message"))
    }
  end

  defp recent_event_payload(_event), do: %{at: nil, event: nil, message: nil}

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp workspace_git_payload(path) when is_binary(path) do
    if File.dir?(path) do
      case git(path, ["status", "--porcelain=v1", "--branch"]) do
        {:ok, status} -> workspace_git_from_status(path, status)
        {:error, reason} -> workspace_git_unavailable("git status failed: #{reason}")
      end
    else
      workspace_git_unavailable("workspace missing")
    end
  end

  defp workspace_git_payload(_path), do: workspace_git_unavailable("workspace unavailable")

  defp workspace_git_from_status(path, status) do
    branch = branch_payload(status)
    head = head_payload(path)

    %{
      available: true,
      branch: branch.branch,
      branch_label: branch.label,
      detached: branch.detached,
      rebasing: rebasing?(path),
      head: head,
      base: base_payload(path),
      relation: relation_payload(path),
      branch_diff: branch_diff_payload(path),
      working_tree: working_tree_payload(status),
      published: published_payload(path, branch.branch, head)
    }
  end

  defp workspace_git_unavailable(reason), do: %{available: false, reason: reason}

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {output, _status} -> {:error, output |> String.trim() |> compact_detail()}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp branch_payload(status) do
    status
    |> String.split("\n", parts: 2)
    |> List.first()
    |> parse_branch_line()
  end

  defp parse_branch_line("## HEAD" <> _rest), do: %{branch: nil, label: "detached HEAD", detached: true}

  defp parse_branch_line("## " <> branch_line) do
    branch =
      branch_line
      |> String.split(["...", " "], parts: 2)
      |> List.first()

    %{branch: branch, label: branch, detached: false}
  end

  defp parse_branch_line(_line), do: %{branch: nil, label: "unknown", detached: false}

  defp head_payload(path) do
    case git(path, ["log", "-1", "--format=%H%x00%s"]) do
      {:ok, output} ->
        case String.split(output, <<0>>, parts: 2) do
          [sha, subject] -> %{sha: sha, short_sha: short_sha(sha), subject: subject}
          [sha] -> %{sha: sha, short_sha: short_sha(sha), subject: nil}
        end

      {:error, reason} ->
        %{sha: nil, short_sha: nil, subject: reason}
    end
  end

  defp base_payload(path) do
    case git(path, ["rev-parse", "--verify", "origin/main"]) do
      {:ok, sha} -> %{name: "origin/main", sha: sha, short_sha: short_sha(sha)}
      {:error, reason} -> %{name: "origin/main", sha: nil, short_sha: nil, error: reason}
    end
  end

  defp relation_payload(path) do
    case git(path, ["rev-list", "--left-right", "--count", "origin/main...HEAD"]) do
      {:ok, output} ->
        case output |> String.split(~r/\s+/, trim: true) |> Enum.map(&Integer.parse/1) do
          [{behind, ""}, {ahead, ""}] -> %{ahead: ahead, behind: behind}
          _ -> %{ahead: nil, behind: nil}
        end

      {:error, _reason} ->
        %{ahead: nil, behind: nil}
    end
  end

  defp branch_diff_payload(path) do
    case git(path, ["diff", "--name-status", "origin/main...HEAD"]) do
      {:ok, output} ->
        files =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&branch_diff_file_payload/1)

        %{changed_count: length(files), files: Enum.take(files, @changed_files_limit), hidden_count: max(length(files) - @changed_files_limit, 0)}

      {:error, reason} ->
        %{changed_count: nil, files: [], hidden_count: 0, error: reason}
    end
  end

  defp branch_diff_file_payload(line) do
    [status | paths] = String.split(line, "\t", trim: true)
    path = List.last(paths) || ""

    %{
      path: path,
      status: status,
      kind: branch_diff_kind(status)
    }
  end

  defp published_payload(_path, nil, _head), do: %{branch: nil, has_remote_branch: false, head_pushed: false, published: false}

  defp published_payload(path, branch, head) do
    case git(path, ["rev-parse", "--verify", "refs/remotes/origin/#{branch}"]) do
      {:ok, sha} ->
        head_pushed = Map.get(head, :sha) == sha

        %{
          branch: "origin/#{branch}",
          has_remote_branch: true,
          head_pushed: head_pushed,
          published: head_pushed,
          sha: sha,
          short_sha: short_sha(sha)
        }

      {:error, _reason} ->
        %{branch: "origin/#{branch}", has_remote_branch: false, head_pushed: false, published: false}
    end
  end

  defp working_tree_payload(status) do
    files =
      status
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "## "))
      |> Enum.map(&changed_file_payload/1)

    conflict_count = Enum.count(files, & &1.conflict)

    %{
      clean: files == [],
      changed_count: length(files),
      staged_count: Enum.count(files, & &1.staged),
      unstaged_count: Enum.count(files, & &1.unstaged),
      untracked_count: Enum.count(files, &(&1.kind == "untracked")),
      conflict_count: conflict_count,
      files: Enum.take(files, @changed_files_limit),
      hidden_count: max(length(files) - @changed_files_limit, 0)
    }
  end

  defp changed_file_payload("?? " <> path) do
    %{path: path, status: "??", kind: "untracked", staged: false, unstaged: false, conflict: false}
  end

  defp changed_file_payload(line) do
    status = String.slice(line, 0, 2)
    path = line |> String.slice(3..-1//1) |> to_string()

    %{
      path: path,
      status: status,
      kind: file_change_kind(status),
      staged: String.at(status, 0) not in [" ", "?"],
      unstaged: String.at(status, 1) not in [" ", "?"],
      conflict: conflict_status?(status)
    }
  end

  defp file_change_kind(status) do
    cond do
      conflict_status?(status) -> "conflict"
      String.contains?(status, "A") -> "added"
      String.contains?(status, "D") -> "deleted"
      String.contains?(status, "R") -> "renamed"
      String.contains?(status, "M") -> "modified"
      true -> "changed"
    end
  end

  defp branch_diff_kind("A" <> _rest), do: "added"
  defp branch_diff_kind("D" <> _rest), do: "deleted"
  defp branch_diff_kind("R" <> _rest), do: "renamed"
  defp branch_diff_kind("M" <> _rest), do: "modified"
  defp branch_diff_kind(_status), do: "changed"

  defp conflict_status?(status), do: status in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

  defp rebasing?(path) do
    case git(path, ["rev-parse", "--git-dir"]) do
      {:ok, git_dir} ->
        git_dir = Path.expand(git_dir, path)
        File.exists?(Path.join(git_dir, "rebase-merge")) or File.exists?(Path.join(git_dir, "rebase-apply"))

      {:error, _reason} ->
        false
    end
  end

  defp short_sha(sha) when is_binary(sha), do: String.slice(String.trim(sha), 0, 7)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
