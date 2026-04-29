defmodule SymphonyElixir.LinearViewInstallerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LinearViewInstaller

  test "creates shared project workflow views and sidebar favorites" do
    parent = self()

    assert {:ok, results} =
             LinearViewInstaller.install([], deps(parent, views: [], favorites: []))

    assert Enum.map(results, & &1.view.name) == [
             "Symphony: Project project-slug / All",
             "Symphony: Project project-slug / Ready",
             "Symphony: Project project-slug / Paused",
             "Symphony: Project project-slug / Backlog",
             "Symphony: Project project-slug / Todo",
             "Symphony: Project project-slug / In Progress",
             "Symphony: Project project-slug / Done"
           ]

    assert Enum.all?(results, &(&1.action == :created))
    assert Enum.all?(results, &(&1.context.favorite_action == :created))

    created_views = received_messages(:view_created)
    assert length(created_views) == 7

    ready_input =
      created_views
      |> Enum.map(& &1.input)
      |> Enum.find(&(&1.name == "Symphony: Project project-slug / Ready"))

    assert ready_input.filterData.project.id.eq == "project-project-slug"
    assert ready_input.filterData.labels.some.name.eq == "agent-ready"

    paused_input =
      created_views
      |> Enum.map(& &1.input)
      |> Enum.find(&(&1.name == "Symphony: Project project-slug / Paused"))

    assert paused_input.filterData.project.id.eq == "project-project-slug"
    assert paused_input.filterData.labels.some.name.eq == "agent-paused"

    backlog_input =
      created_views
      |> Enum.map(& &1.input)
      |> Enum.find(&(&1.name == "Symphony: Project project-slug / Backlog"))

    assert backlog_input.shared == true
    assert backlog_input.teamId == "team-1"
    assert backlog_input.filterData.project.id.eq == "project-project-slug"
    assert backlog_input.filterData.state.name.eq == "Backlog"

    created_favorites = received_messages(:favorite_created)
    assert Enum.any?(created_favorites, &match?(%{input: %{folderName: "Symphony"}}, &1))
    assert Enum.count(created_favorites, &match?(%{input: %{customViewId: _, parentId: "favorite-folder"}}, &1)) == 7
  end

  test "updates an existing view when its filter or sharing differs" do
    parent = self()

    existing_view = %{
      "id" => "view-backlog",
      "name" => "Symphony: Project project-slug / Backlog",
      "description" => "Old description",
      "filterData" => %{"state" => %{"name" => %{"eq" => "Todo"}}},
      "shared" => false,
      "slugId" => "old-slug",
      "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
    }

    assert {:ok, results} =
             LinearViewInstaller.install(
               [],
               deps(parent,
                 views: [existing_view],
                 favorites: [folder_favorite()],
                 states: [state("Backlog", "backlog", 0)]
               )
             )

    assert Enum.map(results, & &1.action) == [:created, :created, :created, :updated]
    assert_received {:view_updated, %{id: "view-backlog", input: input}}
    assert input.shared == true
    assert input.filterData.project.id.eq == "project-project-slug"
    assert input.filterData.state.name.eq == "Backlog"
  end

  test "keeps matching views unchanged and skips favorites when requested" do
    parent = self()

    matching_view = %{
      "id" => "view-backlog",
      "name" => "Symphony: Project project-slug / Backlog",
      "description" => "Issues in Project project-slug currently in Backlog.",
      "filterData" => %{
        "project" => %{"id" => %{"eq" => "project-project-slug"}},
        "state" => %{"name" => %{"eq" => "Backlog"}}
      },
      "shared" => true,
      "slugId" => "backlog-slug",
      "team" => %{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}
    }

    assert {:ok, results} =
             LinearViewInstaller.install(
               [skip_favorites: true],
               deps(parent,
                 views: [matching_view],
                 favorites: [],
                 states: [state("Backlog", "backlog", 0)]
               )
             )

    assert Enum.map(results, & &1.action) == [:created, :created, :created, :unchanged]
    assert Enum.all?(results, &(&1.context.favorite_action == :skipped))
    refute_received {:favorite_created, _variables}
    refute_received {:view_updated, _variables}
  end

  defp deps(parent, opts) do
    project_response =
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               project(Keyword.get(opts, :states, default_states()))
             ]
           }
         }
       }}

    views = Keyword.get(opts, :views, [])
    favorites = Keyword.get(opts, :favorites, [])

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
      settings: Keyword.get(opts, :settings, fn -> %{tracker: %{project_slug: "project-slug", project_slugs: ["project-slug"], active_states: ["Todo", "In Progress"]}} end),
      ensure_req_started: fn -> {:ok, [:req]} end,
      linear_graphql: fn query, variables ->
        cond do
          String.contains?(query, "customViewCreate") ->
            send(parent, {:view_created, variables})
            {:ok, %{"data" => %{"customViewCreate" => %{"success" => true, "customView" => view_from_input("view-created-#{length(received_messages(:view_created))}", variables.input)}}}}

          String.contains?(query, "customViewUpdate") ->
            send(parent, {:view_updated, variables})
            {:ok, %{"data" => %{"customViewUpdate" => %{"success" => true, "customView" => view_from_input(variables.id, variables.input)}}}}

          String.contains?(query, "favoriteCreate") ->
            send(parent, {:favorite_created, variables})
            {:ok, %{"data" => %{"favoriteCreate" => %{"success" => true, "favorite" => favorite_from_input(variables.input)}}}}

          String.contains?(query, "SymphonyViewProject") ->
            project_response

          String.contains?(query, "customViews") ->
            {:ok, %{"data" => %{"customViews" => %{"nodes" => views}, "favorites" => %{"nodes" => favorites}}}}
        end
      end
    }
  end

  defp project(states) do
    %{
      "id" => "project-project-slug",
      "name" => "Project project-slug",
      "slugId" => "project-slug",
      "url" => "https://linear.app/acme/project/project-slug",
      "teams" => %{
        "nodes" => [
          %{"id" => "team-1", "key" => "ENG", "name" => "Engineering", "states" => %{"nodes" => states}}
        ]
      }
    }
  end

  defp default_states do
    [
      state("Backlog", "backlog", 0),
      state("Todo", "unstarted", 1),
      state("In Progress", "started", 2),
      state("Done", "completed", 3),
      state("Canceled", "canceled", 4)
    ]
  end

  defp state(name, type, position) do
    %{"id" => "state-#{name}", "name" => name, "type" => type, "position" => position}
  end

  defp folder_favorite do
    %{
      "id" => "favorite-folder",
      "type" => "folder",
      "folderName" => "Symphony",
      "title" => "Symphony",
      "url" => nil,
      "sortOrder" => 1000
    }
  end

  defp view_from_input(id, input) do
    %{
      "id" => id,
      "name" => input.name,
      "description" => input.description,
      "filterData" => stringify_keys(input.filterData),
      "shared" => input.shared,
      "slugId" => "#{id}-slug",
      "team" => %{"id" => input.teamId, "key" => "ENG", "name" => "Engineering"}
    }
  end

  defp favorite_from_input(%{folderName: folder_name}) do
    %{
      "id" => "favorite-folder",
      "type" => "folder",
      "folderName" => folder_name,
      "title" => folder_name,
      "url" => nil,
      "sortOrder" => 1000
    }
  end

  defp favorite_from_input(%{customViewId: view_id, parentId: parent_id}) do
    %{
      "id" => "favorite-#{view_id}",
      "type" => "customView",
      "folderName" => nil,
      "title" => "Custom view",
      "url" => "https://linear.app/acme/view/#{view_id}",
      "sortOrder" => 1100,
      "customView" => %{"id" => view_id, "name" => "Custom view"},
      "parent" => %{"id" => parent_id, "folderName" => "Symphony", "title" => "Symphony"}
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

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
