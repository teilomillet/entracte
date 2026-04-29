defmodule SymphonyElixir.LinearWorkflowStateInstallerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LinearWorkflowStateInstaller

  test "creates missing configured workflow states between existing ordered states" do
    parent = self()

    assert {:ok, results} =
             LinearWorkflowStateInstaller.install([], deps(parent, states: default_states()))

    assert Enum.map(results, & &1.action) == [
             :unchanged,
             :unchanged,
             :unchanged,
             :created,
             :created,
             :created,
             :unchanged
           ]

    assert Enum.map(results, & &1.state.name) == [
             "Backlog",
             "Todo",
             "In Progress",
             "Human Review",
             "Merging",
             "Rework",
             "Done"
           ]

    created_inputs =
      :created
      |> received_messages()
      |> Enum.map(& &1.input)

    assert Enum.map(created_inputs, & &1.name) == ["Human Review", "Merging", "Rework"]
    assert Enum.all?(created_inputs, &(&1.type == "started"))
    assert Enum.all?(created_inputs, &(&1.teamId == "team-1"))
    assert Enum.map(created_inputs, & &1.position) == [2.25, 2.5, 2.75]
  end

  test "does not rewrite existing workflow states" do
    parent = self()

    existing_human_review =
      state("state-human-review", "Human Review", "started", 2.5, "#111111", "Team-owned copy")

    assert {:ok, results} =
             LinearWorkflowStateInstaller.install(
               [],
               deps(parent, states: default_states() ++ [existing_human_review])
             )

    assert Enum.find(results, &(&1.state.name == "Human Review")).action == :unchanged
    refute Enum.any?(received_messages(:created), &(&1.input.name == "Human Review"))
  end

  test "creates one state set for multiple projects on the same team" do
    parent = self()
    shared_team = team("team-1", "ENG", default_states())

    project_responses = %{
      "project-a" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-a", shared_team)]}}}},
      "project-b" => {:ok, %{"data" => %{"projects" => %{"nodes" => [project("project-b", shared_team)]}}}}
    }

    assert {:ok, results} =
             LinearWorkflowStateInstaller.install(
               [],
               deps(parent,
                 project_responses: project_responses,
                 settings: fn ->
                   %{
                     tracker: %{
                       project_slugs: ["project-a", "project-b"],
                       bootstrap_states: ["Human Review"],
                       terminal_states: ["Done"]
                     }
                   }
                 end
               )
             )

    assert [%{action: :created, state: %{name: "Human Review"}}] = results
    assert Enum.map(List.first(results).projects, & &1.slug) == ["project-a", "project-b"]
    assert length(received_messages(:created)) == 1
  end

  test "returns project lookup errors" do
    assert {:error, :linear_project_not_found} =
             LinearWorkflowStateInstaller.install(
               [],
               deps(self(), project_response: {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}})
             )
  end

  defp deps(parent, opts) do
    states = Keyword.get(opts, :states, default_states())
    project_response = Keyword.get(opts, :project_response, {:ok, %{"data" => %{"projects" => %{"nodes" => [project(states)]}}}})
    project_responses = Keyword.get(opts, :project_responses, %{})

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
            tracker: %{
              project_slug: "project-slug",
              project_slugs: ["project-slug"],
              bootstrap_states: ["Backlog", "Todo", "In Progress", "Human Review", "Merging", "Rework", "Done"],
              terminal_states: ["Done", "Canceled", "Duplicate"]
            }
          }
        end),
      ensure_req_started: fn -> {:ok, [:req]} end,
      linear_graphql: fn query, variables ->
        cond do
          String.contains?(query, "workflowStateCreate") ->
            send(parent, {:created, variables})

            {:ok,
             %{
               "data" => %{
                 "workflowStateCreate" => %{"success" => true, "workflowState" => state_from_input(variables.input)}
               }
             }}

          String.contains?(query, "projects") ->
            Map.get(project_responses, variables.slug, project_response)
        end
      end
    }
  end

  defp project(states) do
    project("project-slug", team("team-1", "ENG", states))
  end

  defp project(slug, team) do
    %{
      "id" => "project-#{slug}",
      "name" => "Project #{slug}",
      "slugId" => slug,
      "url" => "https://linear.app/acme/project/#{slug}",
      "teams" => %{"nodes" => [team]}
    }
  end

  defp team(id, key, states) do
    %{"id" => id, "key" => key, "name" => "Team #{key}", "states" => %{"nodes" => states}}
  end

  defp default_states do
    [
      state("state-backlog", "Backlog", "backlog", 0, "#bec2c8", nil),
      state("state-todo", "Todo", "unstarted", 1, "#e2e2e2", nil),
      state("state-progress", "In Progress", "started", 2, "#f2c94c", nil),
      state("state-done", "Done", "completed", 3, "#5e6ad2", nil)
    ]
  end

  defp state(id, name, type, position, color, description) do
    %{
      "id" => id,
      "name" => name,
      "type" => type,
      "position" => position,
      "color" => color,
      "description" => description,
      "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Team ENG"}
    }
  end

  defp state_from_input(input) do
    state(
      "state-#{input.name}",
      input.name,
      input.type,
      input.position,
      input.color,
      input.description
    )
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
