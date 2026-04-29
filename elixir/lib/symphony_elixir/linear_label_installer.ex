defmodule SymphonyElixir.LinearLabelInstaller do
  @moduledoc """
  Installs Linear issue labels used by Symphony dispatch guardrails.
  """

  alias SymphonyElixir.{Config, EnvFile, Workflow}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.{Label, LabelInstallation, Project}

  @ready_color "#2ECC71"
  @paused_color "#E03131"
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @project_query """
  query SymphonyLabelProject($slug: String!) {
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
          }
        }
      }
    }
  }
  """

  @labels_query """
  query SymphonyIssueLabels {
    issueLabels(first: 250, includeArchived: false) {
      nodes {
        id
        name
        description
        color
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @label_create_mutation """
  mutation SymphonyIssueLabelCreate($input: IssueLabelCreateInput!) {
    issueLabelCreate(input: $input) {
      success
      issueLabel {
        id
        name
        description
        color
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @label_update_mutation """
  mutation SymphonyIssueLabelUpdate($id: String!, $input: IssueLabelUpdateInput!) {
    issueLabelUpdate(id: $id, input: $input) {
      success
      issueLabel {
        id
        name
        description
        color
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @type action :: :created | :updated | :unchanged
  @type result :: LabelInstallation.t()
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
         {:ok, labels} <- fetch_labels(deps) do
      install_labels(project_team_groups, labels, dispatch_settings(settings), opts, deps)
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

  defp fetch_labels(deps) do
    case deps.linear_graphql.(@labels_query, %{}) do
      {:ok, %{"data" => %{"issueLabels" => %{"nodes" => labels}}}} when is_list(labels) ->
        {:ok, labels}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_labels_unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp install_labels(project_team_groups, labels, dispatch, opts, deps) do
    project_team_groups
    |> desired_label_specs(dispatch)
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, results} ->
      case install_label(spec, labels, update_existing?(opts), deps) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp desired_label_specs(project_team_groups, dispatch) do
    Enum.flat_map(project_team_groups, fn %{team: team, projects: projects} ->
      [
        label_spec(:ready, dispatch.ready_label, @ready_color, "Runner may spend credits on this issue.", team, projects),
        label_spec(:paused, dispatch.paused_label, @paused_color, "Runner must not start or continue this issue.", team, projects)
      ]
    end)
  end

  defp label_spec(kind, name, color, description, team, projects) do
    %{
      kind: kind,
      name: name,
      color: color,
      description: description,
      team: team,
      projects: projects
    }
  end

  defp install_label(spec, labels, update_existing?, deps) do
    case find_existing_label(labels, spec.team["id"], spec.name) do
      nil ->
        create_label(spec, deps)

      existing_label when update_existing? ->
        if label_matches?(existing_label, spec) do
          {:ok, result(:unchanged, existing_label, spec)}
        else
          update_label(existing_label, spec, deps)
        end

      existing_label ->
        {:ok, result(:unchanged, existing_label, spec)}
    end
  end

  defp find_existing_label(labels, team_id, label_name) do
    normalized_label_name = normalize_label_name(label_name)

    Enum.find(labels, fn label ->
      normalize_label_name(label["name"]) == normalized_label_name and get_in(label, ["team", "id"]) == team_id
    end)
  end

  defp label_matches?(label, spec) do
    label["name"] == spec.name and
      label["description"] == spec.description and
      String.downcase(to_string(label["color"])) == String.downcase(spec.color)
  end

  defp create_label(spec, deps) do
    case deps.linear_graphql.(@label_create_mutation, %{input: label_input(spec)}) do
      {:ok, %{"data" => %{"issueLabelCreate" => %{"success" => true, "issueLabel" => label}}}} ->
        {:ok, result(:created, label, spec)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_label_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_label(existing_label, spec, deps) do
    case deps.linear_graphql.(@label_update_mutation, %{id: existing_label["id"], input: label_input(spec)}) do
      {:ok, %{"data" => %{"issueLabelUpdate" => %{"success" => true, "issueLabel" => label}}}} ->
        {:ok, result(:updated, label, spec)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_label_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp label_input(spec) do
    %{
      name: spec.name,
      description: spec.description,
      color: spec.color,
      teamId: spec.team["id"]
    }
  end

  defp result(action, label, spec) do
    %LabelInstallation{
      action: action,
      label: normalize_label(label),
      projects: Enum.map(spec.projects, &normalize_project(&1, spec.team)),
      context: %{
        provider: :linear,
        kind: spec.kind,
        team_id: spec.team["id"],
        team_key: spec.team["key"],
        team_name: spec.team["name"],
        raw_team: spec.team
      }
    }
  end

  defp normalize_label(%{} = label) do
    %Label{
      id: label["id"],
      name: label["name"],
      description: label["description"],
      color: label["color"],
      metadata: %{provider: :linear, raw: label}
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

  defp dispatch_settings(%{dispatch: dispatch}) when is_map(dispatch), do: dispatch
  defp dispatch_settings(_settings), do: %{ready_label: "agent-ready", paused_label: "agent-paused"}

  defp update_existing?(opts), do: Keyword.get(opts, :update_existing, true) == true

  defp normalize_label_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label_name(_value), do: ""
end
