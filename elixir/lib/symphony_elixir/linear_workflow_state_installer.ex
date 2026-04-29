defmodule SymphonyElixir.LinearWorkflowStateInstaller do
  @moduledoc """
  Installs Linear workflow states used by Symphony-runner workflows.
  """

  alias SymphonyElixir.{Config, EnvFile, Workflow}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.{Project, WorkflowState, WorkflowStateInstallation}

  @default_colors %{
    "backlog" => "#BEC2C8",
    "unstarted" => "#E2E2E2",
    "started" => "#F2C94C",
    "completed" => "#5E6AD2",
    "canceled" => "#95A2B3"
  }
  @state_colors %{
    "human review" => "#F2994A",
    "merging" => "#5E6AD2",
    "rework" => "#E03131"
  }
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @project_query """
  query SymphonyWorkflowStateProject($slug: String!) {
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
                color
                description
                position
              }
            }
          }
        }
      }
    }
  }
  """

  @workflow_state_create_mutation """
  mutation SymphonyWorkflowStateCreate($input: WorkflowStateCreateInput!) {
    workflowStateCreate(input: $input) {
      success
      workflowState {
        id
        name
        type
        color
        description
        position
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @type action :: :created | :unchanged
  @type result :: WorkflowStateInstallation.t()
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
         {:ok, project_team_groups} <- resolve_project_team_groups(settings.tracker, deps) do
      install_workflow_states(project_team_groups, settings, deps)
    end
  end

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

  defp install_workflow_states(project_team_groups, settings, deps) do
    project_team_groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, results} ->
      case install_team_workflow_states(group, settings, deps) do
        {:ok, group_results} -> {:cont, {:ok, Enum.reverse(group_results, results)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_team_workflow_states(%{team: team, projects: projects}, settings, deps) do
    existing_states = team |> get_in(["states", "nodes"]) |> normalize_existing_states()

    team
    |> desired_state_specs(settings)
    |> assign_positions(existing_states)
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, results} ->
      spec = Map.put(spec, :projects, Enum.map(projects, &project_struct(&1, team)))

      case install_workflow_state(spec, existing_states, deps) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_existing_states(states) when is_list(states), do: states
  defp normalize_existing_states(_states), do: []

  defp desired_state_specs(team, settings) do
    settings.tracker
    |> bootstrap_state_names()
    |> Enum.with_index()
    |> Enum.map(fn {name, index} ->
      type = state_type(name, settings.tracker)

      %{
        name: name,
        type: type,
        color: state_color(name, type),
        description: "State used by the Symphony runner workflow.",
        index: index,
        team: team
      }
    end)
  end

  defp bootstrap_state_names(tracker) do
    case Map.get(tracker, :bootstrap_states, []) do
      states when is_list(states) ->
        states
        |> Enum.map(&normalize_state_name/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&state_key/1)

      _states ->
        []
    end
  end

  defp normalize_state_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      state -> state
    end
  end

  defp normalize_state_name(_value), do: nil

  defp state_type(name, tracker) do
    name_key = state_key(name)
    terminal_keys = tracker |> Map.get(:terminal_states, []) |> Enum.map(&state_key/1) |> MapSet.new()

    cond do
      name_key == "backlog" ->
        "backlog"

      name_key in ["todo", "to do"] ->
        "unstarted"

      MapSet.member?(terminal_keys, name_key) ->
        terminal_state_type(name_key)

      true ->
        "started"
    end
  end

  defp terminal_state_type(name_key) when name_key in ["canceled", "cancelled", "duplicate"], do: "canceled"
  defp terminal_state_type(_name_key), do: "completed"

  defp state_color(name, type) do
    Map.get(@state_colors, state_key(name), Map.fetch!(@default_colors, type))
  end

  defp assign_positions(specs, existing_states) do
    existing_by_name = existing_states_by_name(existing_states)

    Enum.map(specs, fn spec ->
      Map.put(spec, :position, desired_position(spec.index, specs, existing_by_name))
    end)
  end

  defp desired_position(index, specs, existing_by_name) do
    case existing_position(Enum.at(specs, index), existing_by_name) do
      position when is_number(position) ->
        position

      _ ->
        interpolate_missing_position(index, specs, existing_by_name)
    end
  end

  defp interpolate_missing_position(index, specs, existing_by_name) do
    previous = previous_anchor(index, specs, existing_by_name)
    next = next_anchor(index, specs, existing_by_name)

    case {previous, next} do
      {%{index: previous_index, position: previous_position}, %{index: next_index, position: next_position}}
      when next_position > previous_position ->
        previous_position +
          (next_position - previous_position) * (index - previous_index) / (next_index - previous_index)

      {%{index: previous_index, position: previous_position}, _next} ->
        previous_position + index - previous_index

      {_previous, %{index: next_index, position: next_position}} ->
        next_position - (next_index - index)

      {_previous, _next} ->
        index * 1.0
    end
  end

  defp previous_anchor(index, specs, existing_by_name) do
    specs
    |> Enum.take(index)
    |> Enum.reverse()
    |> Enum.find_value(&anchor_for_spec(&1, existing_by_name))
  end

  defp next_anchor(index, specs, existing_by_name) do
    specs
    |> Enum.drop(index + 1)
    |> Enum.find_value(&anchor_for_spec(&1, existing_by_name))
  end

  defp anchor_for_spec(spec, existing_by_name) do
    case existing_position(spec, existing_by_name) do
      position when is_number(position) -> %{index: spec.index, position: position}
      _ -> nil
    end
  end

  defp existing_position(spec, existing_by_name) do
    case Map.get(existing_by_name, state_key(spec.name)) do
      %{"position" => position} when is_number(position) -> position
      _ -> nil
    end
  end

  defp existing_states_by_name(states) do
    Map.new(states, fn state -> {state_key(state["name"]), state} end)
  end

  defp install_workflow_state(spec, existing_states, deps) do
    case find_existing_state(existing_states, spec.name) do
      nil -> create_workflow_state(spec, deps)
      existing_state -> {:ok, result(:unchanged, existing_state, spec)}
    end
  end

  defp find_existing_state(states, name) do
    Enum.find(states, &(state_key(&1["name"]) == state_key(name)))
  end

  defp create_workflow_state(spec, deps) do
    case deps.linear_graphql.(@workflow_state_create_mutation, %{input: state_input(spec)}) do
      {:ok, %{"data" => %{"workflowStateCreate" => %{"success" => true, "workflowState" => state}}}} ->
        {:ok, result(:created, state, spec)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_workflow_state_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp state_input(spec) do
    %{
      teamId: spec.team["id"],
      name: spec.name,
      type: spec.type,
      color: spec.color,
      description: spec.description,
      position: spec.position
    }
  end

  defp result(action, state, spec) do
    %WorkflowStateInstallation{
      action: action,
      state: normalize_workflow_state(state),
      projects: spec.projects,
      context: team_context(spec.team)
    }
  end

  defp normalize_workflow_state(state) do
    %WorkflowState{
      id: state["id"],
      name: state["name"],
      type: state["type"],
      color: state["color"],
      description: state["description"],
      position: state["position"],
      metadata: %{provider: :linear, raw: state}
    }
  end

  defp project_struct(project, team) do
    %Project{
      id: project["id"],
      name: project["name"],
      slug: project["slugId"],
      url: project["url"],
      team_id: team["id"],
      team_key: team["key"],
      team_name: team["name"],
      metadata: %{provider: :linear, raw: project, team: team}
    }
  end

  defp team_context(team) do
    %{
      provider: :linear,
      team_id: team["id"],
      team_key: team["key"],
      team_name: team["name"]
    }
  end

  defp state_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp state_key(_value), do: ""
end
