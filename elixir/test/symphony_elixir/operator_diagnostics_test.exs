defmodule SymphonyElixir.OperatorDiagnosticsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.OperatorDiagnostics
  alias SymphonyElixir.Tracker.{Issue, Project}

  test "ticket preview explains dispatch gates for active issues" do
    issues = [
      issue("DGE-1", labels: ["agent-ready"], assignee_id: "viewer-id"),
      issue("DGE-2", labels: [], assignee_id: "viewer-id"),
      issue("DGE-3", labels: ["agent-ready", "agent-paused"], assignee_id: "viewer-id"),
      issue("DGE-4", labels: ["agent-ready"], assignee_id: "other-user")
    ]

    assert {:ok, previews} =
             OperatorDiagnostics.ticket_preview([], deps(fetch_issues_by_states: fn ["Todo", "In Progress"] -> {:ok, issues} end))

    assert %{status: :ready, reasons: []} = Enum.find(previews, &(&1.identifier == "DGE-1"))
    assert %{status: :skipped, reasons: ["missing agent-ready"]} = Enum.find(previews, &(&1.identifier == "DGE-2"))

    assert %{status: :skipped, reasons: paused_reasons} = Enum.find(previews, &(&1.identifier == "DGE-3"))
    assert "has agent-paused" in paused_reasons

    assert %{status: :skipped, reasons: assignee_reasons} = Enum.find(previews, &(&1.identifier == "DGE-4"))
    assert "assignee does not match runner filter" in assignee_reasons
  end

  test "doctor reports visible project matches and dashboard status" do
    project = %Project{name: "backend", slug: "backend-slug", url: "https://linear.app/project/backend-slug"}

    assert {:ok, report} =
             OperatorDiagnostics.doctor(
               [],
               deps(
                 list_projects: fn -> {:ok, [project]} end,
                 fetch_issues_by_states: fn _states -> {:ok, []} end,
                 dashboard_running?: fn 4100 -> true end,
                 settings: fn -> settings(server_port: 4100) end
               )
             )

    assert report.configured_project_slugs == ["backend-slug"]
    assert report.project_matches == [project]
    assert report.dashboard.running? == true

    formatted = OperatorDiagnostics.format_doctor(report)
    assert formatted =~ "matching project(s): backend slug=backend-slug"
    assert formatted =~ "running at http://127.0.0.1:4100"
  end

  defp deps(overrides) do
    base = %{
      file_regular?: fn _path -> true end,
      load_env_file: fn _path -> :ok end,
      load_env_file_if_present: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      settings: fn -> settings() end,
      smoke_check: fn _opts -> {:ok, [%{status: :ok, check: "workflow config", message: "valid"}]} end,
      ensure_req_started: fn -> {:ok, [:req]} end,
      list_projects: fn -> {:ok, []} end,
      fetch_issues_by_states: fn _states -> {:ok, []} end,
      linear_graphql: fn
        query, _variables ->
          cond do
            String.contains?(query, "viewer") ->
              {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id", "name" => "Viewer"}}}}

            String.contains?(query, "organization") ->
              {:ok, %{"data" => %{"organization" => %{"name" => "DGEF", "urlKey" => "dgef"}, "teams" => %{"nodes" => []}}}}
          end
      end,
      dashboard_running?: fn _port -> false end
    }

    Map.merge(base, Map.new(overrides))
  end

  defp settings(opts \\ []) do
    %Schema{
      tracker: %Schema.Tracker{
        kind: "linear",
        project_slug: "backend-slug",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done"],
        assignee: "me"
      },
      dispatch: %Schema.Dispatch{require_ready_label: true, ready_label: "agent-ready", paused_label: "agent-paused"},
      workspace: %Schema.Workspace{root: Path.join(System.tmp_dir!(), "symphony-operator-diagnostics-test")},
      runtime: %Schema.Runtime{preset: "codex/app_server"},
      server: %Schema.Server{port: Keyword.get(opts, :server_port, 4000)}
    }
  end

  defp issue(identifier, opts) do
    %Issue{
      id: "#{identifier}-id",
      identifier: identifier,
      title: "Ticket #{identifier}",
      state: Keyword.get(opts, :state, "Todo"),
      project: %Project{name: "backend", slug: "backend-slug"},
      assignee_id: Keyword.fetch!(opts, :assignee_id),
      labels: Keyword.fetch!(opts, :labels),
      blocked_by: []
    }
  end
end
