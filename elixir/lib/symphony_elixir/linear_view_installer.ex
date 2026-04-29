defmodule SymphonyElixir.LinearViewInstaller do
  @moduledoc """
  Installs Linear custom views and sidebar favorites for Symphony-runner work.
  """

  alias SymphonyElixir.{Config, EnvFile, Workflow}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.{Project, View, ViewInstallation}

  @default_folder_name "Symphony"
  @default_view_prefix "Symphony"
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @project_query """
  query SymphonyViewProject($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        name
        slugId
        url
        teams(first: 10) {
          nodes {
            id
            key
            name
            states {
              nodes {
                id
                name
                type
                position
              }
            }
          }
        }
      }
    }
  }
  """

  @navigation_query """
  query SymphonyViewsAndFavorites {
    customViews(first: 250, includeArchived: false) {
      nodes {
        id
        name
        description
        filterData
        shared
        slugId
        team {
          id
          key
          name
        }
      }
    }
    favorites(first: 250, includeArchived: false) {
      nodes {
        id
        type
        folderName
        title
        url
        sortOrder
        customView {
          id
          name
        }
        parent {
          id
          folderName
          title
        }
      }
    }
  }
  """

  @view_create_mutation """
  mutation SymphonyViewCreate($input: CustomViewCreateInput!) {
    customViewCreate(input: $input) {
      success
      customView {
        id
        name
        description
        filterData
        shared
        slugId
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @view_update_mutation """
  mutation SymphonyViewUpdate($id: String!, $input: CustomViewUpdateInput!) {
    customViewUpdate(id: $id, input: $input) {
      success
      customView {
        id
        name
        description
        filterData
        shared
        slugId
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @favorite_create_mutation """
  mutation SymphonyFavoriteCreate($input: FavoriteCreateInput!) {
    favoriteCreate(input: $input) {
      success
      favorite {
        id
        type
        folderName
        title
        url
        sortOrder
        customView {
          id
          name
        }
        parent {
          id
          folderName
          title
        }
      }
    }
  }
  """

  @type action :: :created | :updated | :unchanged
  @type result :: ViewInstallation.t()
  @type deps :: %{
          required(:load_env_file) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (String.t() -> :ok | {:error, term()}),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:validate_config) => (-> :ok | {:error, term()}),
          required(:settings) => (-> map()),
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:linear_graphql) => (String.t(), map() -> {:ok, map()} | {:error, term()})
        }

  @spec install(keyword(), deps()) :: {:ok, [result()]} | {:error, term()}
  def install(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    workflow_path = opts |> Keyword.get(:workflow, "WORKFLOW.md") |> Path.expand()

    with :ok <- load_env(opts, workflow_path, deps),
         :ok <- deps.set_workflow_file_path.(workflow_path) do
      install_for_current_workflow(opts, deps)
    end
  end

  @spec install_for_current_workflow(keyword(), deps()) :: {:ok, [result()]} | {:error, term()}
  def install_for_current_workflow(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with :ok <- deps.validate_config.(),
         {:ok, _apps} <- deps.ensure_req_started.(),
         settings <- deps.settings.(),
         {:ok, project_team_groups} <- resolve_project_team_groups(settings.tracker, deps),
         {:ok, navigation} <- fetch_navigation(deps),
         {:ok, view_results} <- install_custom_views(project_team_groups, settings, navigation.views, opts, deps) do
      maybe_install_favorites(view_results, navigation.favorites, opts, deps)
    end
  end

  @spec default_folder_name() :: String.t()
  def default_folder_name, do: @default_folder_name

  @spec default_view_prefix() :: String.t()
  def default_view_prefix, do: @default_view_prefix

  defp runtime_deps do
    %{
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      validate_config: &Config.validate!/0,
      settings: &Config.settings!/0,
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      linear_graphql: fn query, variables -> linear_client_module().graphql(query, variables) end
    }
  end

  defp linear_client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp load_env(opts, workflow_path, deps) do
    case Keyword.get(opts, :env_file) do
      nil ->
        load_profile_or_default_env(opts, workflow_path, deps)

      env_file ->
        env_file
        |> Path.expand()
        |> deps.load_env_file.()
    end
  end

  defp load_profile_or_default_env(opts, workflow_path, deps) do
    case Keyword.get(opts, :profile) do
      profile when is_binary(profile) ->
        profile
        |> profile_env_file()
        |> case do
          {:ok, env_file} -> deps.load_env_file.(env_file)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        workflow_path
        |> Path.dirname()
        |> Path.join(".env")
        |> deps.load_env_file_if_present.()
    end
  end

  defp profile_env_file(profile) do
    trimmed = String.trim(profile)

    if Regex.match?(@profile_pattern, trimmed) do
      {:ok, Path.expand(".env.#{trimmed}")}
    else
      {:error, :invalid_profile}
    end
  end

  defp resolve_project_team_groups(tracker, deps) do
    tracker
    |> project_slugs()
    |> resolve_project_team_groups_for_slugs(deps)
  end

  defp resolve_project_team_groups_for_slugs([], _deps), do: {:error, :missing_linear_project_slug}

  defp resolve_project_team_groups_for_slugs(slugs, deps) do
    case fetch_project_teams(slugs, deps) do
      {:ok, project_teams} -> {:ok, project_teams |> Enum.reverse() |> group_project_teams_by_team()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_project_teams(slugs, deps) do
    Enum.reduce_while(slugs, {:ok, []}, &fetch_project_team(&1, &2, deps))
  end

  defp fetch_project_team(project_slug, {:ok, acc}, deps) do
    case resolve_project_and_team(project_slug, deps) do
      {:ok, project, team} -> {:cont, {:ok, [%{project: project, team: team} | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp resolve_project_and_team(project_slug, deps) when is_binary(project_slug) do
    case deps.linear_graphql.(@project_query, %{slug: project_slug}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} ->
        case get_in(project, ["teams", "nodes"]) do
          [team | _] -> {:ok, project, team}
          _ -> {:error, :linear_project_has_no_team}
        end

      {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
        {:error, :linear_project_not_found}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_project_unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_project_and_team(_project_slug, _deps), do: {:error, :missing_linear_project_slug}

  defp project_slugs(tracker) do
    case Map.get(tracker, :project_slugs, []) do
      slugs when is_list(slugs) and slugs != [] ->
        slugs
        |> Enum.map(&normalize_project_slug/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        tracker
        |> Map.get(:project_slug)
        |> normalize_project_slug()
        |> case do
          nil -> []
          slug -> [slug]
        end
    end
  end

  defp normalize_project_slug(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      slug -> slug
    end
  end

  defp normalize_project_slug(_value), do: nil

  defp group_project_teams_by_team(project_teams) do
    project_teams
    |> Enum.reduce([], &put_project_team_group/2)
    |> Enum.map(fn group -> %{group | projects: Enum.reverse(group.projects)} end)
    |> Enum.reverse()
  end

  defp put_project_team_group(%{project: project, team: team}, groups) do
    case Enum.find_index(groups, &(get_in(&1, [:team, "id"]) == team["id"])) do
      nil -> [%{team: team, projects: [project]} | groups]
      index -> List.update_at(groups, index, fn group -> %{group | projects: [project | group.projects]} end)
    end
  end

  defp fetch_navigation(deps) do
    case deps.linear_graphql.(@navigation_query, %{}) do
      {:ok, %{"data" => %{"customViews" => %{"nodes" => views}, "favorites" => %{"nodes" => favorites}}}}
      when is_list(views) and is_list(favorites) ->
        {:ok, %{views: views, favorites: favorites}}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_views_unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp install_custom_views(project_team_groups, settings, existing_views, opts, deps) do
    project_team_groups
    |> desired_view_specs(settings, opts)
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, results} ->
      case install_custom_view(spec, existing_views, update_existing?(opts), deps) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp desired_view_specs(project_team_groups, settings, opts) do
    Enum.flat_map(project_team_groups, fn %{team: team, projects: projects} ->
      Enum.flat_map(projects, fn project ->
        project_view_specs(project, team, settings, opts)
      end)
    end)
  end

  defp project_view_specs(project, team, settings, opts) do
    dispatch = dispatch_settings(settings)

    all_spec = %{
      kind: :all,
      name: view_name(project, "All", opts),
      description: "All issues in #{project_label(project)} visible to the Symphony runner.",
      filter_data: %{project: %{id: %{eq: project["id"]}}},
      state_name: nil,
      project: project,
      team: team
    }

    ready_spec = %{
      kind: :ready,
      name: view_name(project, "Ready", opts),
      description: "Issues in #{project_label(project)} marked ready for the Symphony runner.",
      filter_data: %{project: %{id: %{eq: project["id"]}}, labels: %{some: %{name: %{eq: dispatch.ready_label}}}},
      state_name: nil,
      project: project,
      team: team
    }

    paused_spec = %{
      kind: :paused,
      name: view_name(project, "Paused", opts),
      description: "Issues in #{project_label(project)} paused for the Symphony runner.",
      filter_data: %{project: %{id: %{eq: project["id"]}}, labels: %{some: %{name: %{eq: dispatch.paused_label}}}},
      state_name: nil,
      project: project,
      team: team
    }

    state_specs =
      team
      |> state_names_for_team(settings.tracker)
      |> Enum.map(fn state_name ->
        %{
          kind: :state,
          name: view_name(project, state_name, opts),
          description: "Issues in #{project_label(project)} currently in #{state_name}.",
          filter_data: %{project: %{id: %{eq: project["id"]}}, state: %{name: %{eq: state_name}}},
          state_name: state_name,
          project: project,
          team: team
        }
      end)

    [all_spec, ready_spec, paused_spec | state_specs]
  end

  defp state_names_for_team(team, tracker) do
    case get_in(team, ["states", "nodes"]) do
      states when is_list(states) and states != [] ->
        states
        |> Enum.filter(&workflow_state?/1)
        |> Enum.sort_by(&state_sort_key/1)
        |> Enum.map(& &1["name"])
        |> Enum.reject(&blank?/1)
        |> Enum.uniq()

      _states ->
        fallback_state_names(tracker)
    end
  end

  defp workflow_state?(%{"type" => "canceled"}), do: false
  defp workflow_state?(%{"name" => name}), do: not blank?(name)
  defp workflow_state?(_state), do: false

  defp state_sort_key(state) do
    {state["position"] || 9_999, String.downcase(to_string(state["name"] || ""))}
  end

  defp fallback_state_names(tracker) do
    ["Backlog"]
    |> Kernel.++(Map.get(tracker, :active_states, []))
    |> Kernel.++(["Done"])
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_state_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      state -> state
    end
  end

  defp normalize_state_name(_value), do: nil

  defp view_name(project, suffix, opts) do
    "#{view_prefix(opts)}: #{project_label(project)} / #{suffix}"
  end

  defp project_label(project) do
    project["name"] || project["slugId"] || "unnamed project"
  end

  defp install_custom_view(spec, existing_views, update_existing?, deps) do
    case find_existing_view(existing_views, spec.team["id"], spec.name) do
      nil ->
        create_view(spec, deps)

      existing_view when update_existing? ->
        if view_matches?(existing_view, spec) do
          {:ok, result(:unchanged, existing_view, spec)}
        else
          update_view(existing_view, spec, deps)
        end

      existing_view ->
        {:ok, result(:unchanged, existing_view, spec)}
    end
  end

  defp find_existing_view(views, team_id, view_name) do
    Enum.find(views, fn view ->
      view["name"] == view_name and get_in(view, ["team", "id"]) == team_id
    end)
  end

  defp view_matches?(existing_view, spec) do
    existing_view["description"] == spec.description and
      existing_view["shared"] == true and
      stringify_keys(existing_view["filterData"] || %{}) == stringify_keys(spec.filter_data)
  end

  defp create_view(spec, deps) do
    case deps.linear_graphql.(@view_create_mutation, %{input: view_input(spec)}) do
      {:ok, %{"data" => %{"customViewCreate" => %{"success" => true, "customView" => view}}}} ->
        {:ok, result(:created, view, spec)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_view_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_view(existing_view, spec, deps) do
    case deps.linear_graphql.(@view_update_mutation, %{id: existing_view["id"], input: view_input(spec)}) do
      {:ok, %{"data" => %{"customViewUpdate" => %{"success" => true, "customView" => view}}}} ->
        {:ok, result(:updated, view, spec)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_view_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp view_input(spec) do
    %{
      name: spec.name,
      description: spec.description,
      teamId: spec.team["id"],
      shared: true,
      filterData: spec.filter_data
    }
  end

  defp maybe_install_favorites(results, favorites, opts, deps) do
    if favorite_views?(opts) do
      with {:ok, folder, folder_action} <- ensure_folder_favorite(favorites, opts, deps) do
        ensure_view_favorites(results, favorites, folder, folder_action, deps)
      end
    else
      {:ok, Enum.map(results, &put_context(&1, %{favorite_action: :skipped}))}
    end
  end

  defp favorite_views?(opts) do
    Keyword.get(opts, :favorite_views, true) != false and Keyword.get(opts, :skip_favorites, false) != true
  end

  defp ensure_folder_favorite(favorites, opts, deps) do
    case find_folder_favorite(favorites, folder_name(opts)) do
      nil ->
        create_favorite(%{folderName: folder_name(opts), sortOrder: 1000.0}, deps)
        |> case do
          {:ok, favorite} -> {:ok, favorite, :created}
          {:error, reason} -> {:error, reason}
        end

      folder ->
        {:ok, folder, :unchanged}
    end
  end

  defp find_folder_favorite(favorites, folder_name) do
    Enum.find(favorites, fn favorite ->
      favorite["type"] == "folder" and favorite["folderName"] == folder_name
    end)
  end

  defp ensure_view_favorites(results, favorites, folder, folder_action, deps) do
    results
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], favorites}, fn {result, index}, {:ok, acc, current_favorites} ->
      case ensure_view_favorite(result, current_favorites, folder, folder_action, index, deps) do
        {:ok, updated_result, updated_favorites} -> {:cont, {:ok, [updated_result | acc], updated_favorites}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results, _favorites} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_view_favorite(result, favorites, folder, folder_action, index, deps) do
    case find_custom_view_favorite(favorites, result.view.id) do
      nil ->
        input = %{customViewId: result.view.id, parentId: folder["id"], sortOrder: 1100.0 + index}

        case create_favorite(input, deps) do
          {:ok, favorite} ->
            updated_result =
              result
              |> put_favorite_context(favorite, :created, folder, folder_action)
              |> maybe_put_view_url(favorite["url"])

            {:ok, updated_result, [favorite | favorites]}

          {:error, reason} ->
            {:error, reason}
        end

      favorite ->
        updated_result =
          result
          |> put_favorite_context(favorite, :unchanged, folder, folder_action)
          |> maybe_put_view_url(favorite["url"])

        {:ok, updated_result, favorites}
    end
  end

  defp find_custom_view_favorite(favorites, view_id) do
    Enum.find(favorites, fn favorite ->
      favorite["type"] == "customView" and get_in(favorite, ["customView", "id"]) == view_id
    end)
  end

  defp create_favorite(input, deps) do
    case deps.linear_graphql.(@favorite_create_mutation, %{input: input}) do
      {:ok, %{"data" => %{"favoriteCreate" => %{"success" => true, "favorite" => favorite}}}} ->
        {:ok, favorite}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_favorite_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_favorite_context(result, favorite, favorite_action, folder, folder_action) do
    put_context(result, %{
      favorite_action: favorite_action,
      favorite_id: favorite["id"],
      favorite_url: favorite["url"],
      favorite_parent_id: get_in(favorite, ["parent", "id"]) || folder["id"],
      favorite_folder_id: folder["id"],
      favorite_folder_name: folder["folderName"],
      favorite_folder_action: folder_action
    })
  end

  defp put_context(%ViewInstallation{} = result, updates) do
    %{result | context: Map.merge(result.context, updates)}
  end

  defp maybe_put_view_url(result, nil), do: result
  defp maybe_put_view_url(result, ""), do: result
  defp maybe_put_view_url(%ViewInstallation{} = result, url), do: %{result | view: %{result.view | url: url}}

  defp result(action, view, spec) do
    %ViewInstallation{
      action: action,
      view: normalize_view(view),
      projects: [normalize_project(spec.project, spec.team)],
      context: %{
        provider: :linear,
        kind: spec.kind,
        state_name: spec.state_name,
        team_id: spec.team["id"],
        team_key: spec.team["key"],
        team_name: spec.team["name"],
        raw_team: spec.team,
        favorite_action: :pending
      }
    }
  end

  defp normalize_view(%{} = view) do
    %View{
      id: view["id"],
      name: view["name"],
      description: view["description"],
      slug: view["slugId"],
      filters: view["filterData"] || %{},
      metadata: %{provider: :linear, raw: view}
    }
  end

  defp normalize_project(%{} = project, team) do
    %Project{
      id: project["id"],
      name: project["name"],
      slug: project["slugId"],
      url: project["url"],
      team_id: team && team["id"],
      team_key: team && team["key"],
      team_name: team && team["name"],
      metadata: %{provider: :linear, raw: project, team: team}
    }
  end

  defp folder_name(opts) do
    case Keyword.get(opts, :folder_name) do
      name when is_binary(name) and name != "" -> name
      _ -> @default_folder_name
    end
  end

  defp view_prefix(opts) do
    case Keyword.get(opts, :view_prefix) do
      prefix when is_binary(prefix) and prefix != "" -> prefix
      _ -> @default_view_prefix
    end
  end

  defp update_existing?(opts), do: Keyword.get(opts, :update_existing, true) == true

  defp dispatch_settings(%{dispatch: dispatch}) when is_map(dispatch), do: dispatch
  defp dispatch_settings(_settings), do: %{ready_label: "agent-ready", paused_label: "agent-paused"}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
