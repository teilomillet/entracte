defmodule SymphonyElixir.LinearLabelInstallerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LinearLabelInstaller

  test "creates ready and paused labels for the configured Linear project team" do
    parent = self()

    assert {:ok, results} =
             LinearLabelInstaller.install([], deps(parent, labels: []))

    assert Enum.map(results, & &1.action) == [:created, :created]
    assert Enum.map(results, & &1.label.name) == ["agent-ready", "agent-paused"]
    assert Enum.map(results, & &1.context.kind) == [:ready, :paused]
    assert Enum.map(results, &(&1.projects |> List.first() |> Map.fetch!(:slug))) == ["project-slug", "project-slug"]

    created_inputs =
      :created
      |> received_messages()
      |> Enum.map(& &1.input)

    assert Enum.map(created_inputs, & &1.name) == ["agent-ready", "agent-paused"]
    assert Enum.all?(created_inputs, &(&1.teamId == "team-1"))
    assert Enum.map(created_inputs, & &1.color) == ["#2ECC71", "#E03131"]
  end

  test "updates existing labels when their visible settings differ" do
    parent = self()

    labels = [
      label("label-ready", "Agent-Ready", "Old description", "#111111"),
      matching_label("label-paused", "agent-paused")
    ]

    assert {:ok, results} =
             LinearLabelInstaller.install([], deps(parent, labels: labels))

    assert Enum.map(results, & &1.action) == [:updated, :unchanged]
    assert_received {:updated, %{id: "label-ready", input: input}}
    assert input.name == "agent-ready"
    assert input.description == "Runner may spend credits on this issue."
    assert input.color == "#2ECC71"
    refute_received {:created, _variables}
  end

  test "leaves existing labels unchanged when updates are disabled" do
    parent = self()

    labels = [
      label("label-ready", "agent-ready", "Old ready description", "#111111"),
      label("label-paused", "agent-paused", "Old paused description", "#222222")
    ]

    assert {:ok, results} =
             LinearLabelInstaller.install([update_existing: false], deps(parent, labels: labels))

    assert Enum.map(results, & &1.action) == [:unchanged, :unchanged]
    refute_received {:updated, _variables}
    refute_received {:created, _variables}
  end

  test "creates one label pair for multiple projects on the same team" do
    parent = self()
    shared_team = team("team-1", "ENG")

    project_responses = %{
      "project-a" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-a", shared_team)]}}}},
      "project-b" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-b", shared_team)]}}}}
    }

    assert {:ok, results} =
             LinearLabelInstaller.install(
               [],
               deps(parent,
                 labels: [],
                 project_responses: project_responses,
                 settings: fn ->
                   %{
                     tracker: %{project_slugs: ["project-a", "project-b"]},
                     dispatch: %{ready_label: "agent-ready", paused_label: "agent-paused"}
                   }
                 end
               )
             )

    assert Enum.map(results, & &1.label.name) == ["agent-ready", "agent-paused"]

    assert Enum.map(results, &Enum.map(&1.projects, fn project -> project.slug end)) == [
             ["project-a", "project-b"],
             ["project-a", "project-b"]
           ]

    assert length(received_messages(:created)) == 2
  end

  test "returns project lookup errors" do
    assert {:error, :linear_project_not_found} =
             LinearLabelInstaller.install(
               [],
               deps(self(), project_response: {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}})
             )
  end

  defp deps(parent, opts) do
    project_response =
      Keyword.get(opts, :project_response, {:ok, %{"data" => %{"projects" => %{"nodes" => [project()]}}}})

    project_responses = Keyword.get(opts, :project_responses, %{})
    labels = Keyword.get(opts, :labels, [])

    %{
      load_env_file: fn path ->
        send(parent, {:load_env_file, path})
        :ok
      end,
      load_env_file_if_present: fn path ->
        send(parent, {:load_env_file_if_present, path})
        :ok
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow, path})
        :ok
      end,
      validate_config: fn -> :ok end,
      settings:
        Keyword.get(opts, :settings, fn ->
          %{
            tracker: %{project_slug: "project-slug", project_slugs: ["project-slug"]},
            dispatch: %{ready_label: "agent-ready", paused_label: "agent-paused"}
          }
        end),
      ensure_req_started: fn -> {:ok, [:req]} end,
      linear_graphql: fn query, variables ->
        cond do
          String.contains?(query, "issueLabelCreate") ->
            send(parent, {:created, variables})
            {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => label_from_input(variables.input)}}}}

          String.contains?(query, "issueLabelUpdate") ->
            send(parent, {:updated, variables})
            {:ok, %{"data" => %{"issueLabelUpdate" => %{"success" => true, "issueLabel" => label_from_input(variables.input, variables.id)}}}}

          String.contains?(query, "issueLabels") ->
            {:ok, %{"data" => %{"issueLabels" => %{"nodes" => labels}}}}

          String.contains?(query, "projects") ->
            Map.get(project_responses, variables.slug, project_response)
        end
      end
    }
  end

  defp project do
    project("project-slug", team("team-1", "ENG"))
  end

  defp project(slug, team) do
    %{
      "id" => "project-#{slug}",
      "name" => "Project #{slug}",
      "slugId" => slug,
      "url" => "https://linear.app/acme/project/#{slug}",
      "teams" => %{
        "nodes" => [
          team
        ]
      }
    }
  end

  defp team(id, key), do: %{"id" => id, "key" => key, "name" => "Team #{key}"}

  defp label(id, name, description, color) do
    %{
      "id" => id,
      "name" => name,
      "description" => description,
      "color" => color,
      "team" => team("team-1", "ENG")
    }
  end

  defp matching_label(id, "agent-ready") do
    label(id, "agent-ready", "Runner may spend credits on this issue.", "#2ECC71")
  end

  defp matching_label(id, "agent-paused") do
    label(id, "agent-paused", "Runner must not start or continue this issue.", "#E03131")
  end

  defp label_from_input(input, id \\ nil) do
    %{
      "id" => id || "label-#{input.name}",
      "name" => input.name,
      "description" => input.description,
      "color" => input.color,
      "team" => team(input.teamId, "ENG")
    }
  end

  defp received_messages(tag) do
    Process.info(self(), :messages)
    |> elem(1)
    |> Enum.flat_map(fn
      {^tag, payload} -> [payload]
      _ -> []
    end)
  end
end
