defmodule SymphonyElixir.LinearTemplateInstaller do
  @moduledoc """
  Installs the default Linear issue template for Symphony-runner tasks.
  """

  alias SymphonyElixir.{Config, EnvFile, Workflow}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.{IssueTemplate, Project, TemplateInstallation}

  @default_template_name "Codex Agent Task"
  @default_template_description "Issue template for work handled by the Entr'acte/Symphony Codex runner."
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @default_issue_description """
  ## Goal
  Describe the exact change wanted.

  ## Context
  Relevant links, files, prior decisions, screenshots, or current behavior.

  ## Scope
  - Include:
  - Exclude:

  ## Acceptance Criteria
  - [ ] Observable result 1
  - [ ] Observable result 2
  - [ ] No unrelated behavior changes

  ## Validation
  - [ ] Command/test/check the agent must run
  - [ ] Manual flow to verify, if relevant

  ## Notes
  Anything the agent should know before starting.
  """

  @project_query """
  query SymphonyTemplateProject($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        name
        slugId
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

  @templates_query """
  query SymphonyTemplates {
    templates {
      id
      type
      name
      description
      templateData
      team {
        id
        key
        name
      }
    }
  }
  """

  @template_create_mutation """
  mutation SymphonyTemplateCreate($input: TemplateCreateInput!) {
    templateCreate(input: $input) {
      success
      template {
        id
        type
        name
        team {
          id
          key
          name
        }
      }
    }
  }
  """

  @template_update_mutation """
  mutation SymphonyTemplateUpdate($id: String!, $input: TemplateUpdateInput!) {
    templateUpdate(id: $id, input: $input) {
      success
      template {
        id
        type
        name
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
  @type result :: TemplateInstallation.t()
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
         {:ok, templates} <- fetch_templates(deps) do
      install_templates(project_team_groups, templates, template_name(opts), update_existing?(opts), deps)
    end
  end

  @spec default_template_name() :: String.t()
  def default_template_name, do: @default_template_name

  @spec default_issue_description() :: String.t()
  def default_issue_description, do: @default_issue_description

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

  defp fetch_templates(deps) do
    case deps.linear_graphql.(@templates_query, %{}) do
      {:ok, %{"data" => %{"templates" => templates}}} when is_list(templates) -> {:ok, templates}
      {:ok, _body} -> {:error, :linear_templates_unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_templates(project_team_groups, templates, template_name, update_existing?, deps) do
    project_team_groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, results} ->
      case install_template(templates, group, template_name, update_existing?, deps) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp install_template(templates, %{team: team} = group, template_name, update_existing?, deps) do
    case find_existing_template(templates, team["id"], template_name) do
      nil ->
        create_template(group, template_name, deps)

      existing_template when update_existing? ->
        update_template(existing_template, group, template_name, deps)

      existing_template ->
        {:ok, result(:unchanged, existing_template, group)}
    end
  end

  defp find_existing_template(templates, team_id, template_name) do
    Enum.find(templates, fn template ->
      template["type"] == "issue" and template["name"] == template_name and get_in(template, ["team", "id"]) == team_id
    end)
  end

  defp create_template(%{team: team} = group, template_name, deps) do
    case deps.linear_graphql.(@template_create_mutation, %{input: create_input(team["id"], template_name)}) do
      {:ok, %{"data" => %{"templateCreate" => %{"success" => true, "template" => template}}}} ->
        {:ok, result(:created, template, group)}

      {:ok, _body} ->
        {:error, :linear_template_create_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_template(existing_template, %{team: team} = group, template_name, deps) do
    variables = %{
      id: existing_template["id"],
      input: update_input(team["id"], template_name)
    }

    case deps.linear_graphql.(@template_update_mutation, variables) do
      {:ok, %{"data" => %{"templateUpdate" => %{"success" => true, "template" => template}}}} ->
        {:ok, result(:updated, template, group)}

      {:ok, _body} ->
        {:error, :linear_template_update_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp result(action, template, %{team: team, projects: [_project | _] = projects}) do
    %TemplateInstallation{
      action: action,
      template: normalize_template(template),
      projects: Enum.map(projects, &normalize_project/1),
      context: %{
        provider: :linear,
        team_id: team["id"],
        team_key: team["key"],
        team_name: team["name"],
        raw_team: team
      }
    }
  end

  defp normalize_project(%{} = project) do
    team = project |> get_in(["teams", "nodes"]) |> first_team()

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

  defp first_team([team | _]) when is_map(team), do: team
  defp first_team(_teams), do: nil

  defp normalize_template(%{} = template) do
    %IssueTemplate{
      id: template["id"],
      name: template["name"],
      description: template["description"],
      body: template_body(template["templateData"]),
      metadata: %{provider: :linear, raw: template, type: template["type"]}
    }
  end

  defp template_body(%{} = template_data), do: template_data["description"]

  defp template_body(template_data) when is_binary(template_data) do
    case Jason.decode(template_data) do
      {:ok, decoded} when is_map(decoded) -> template_body(decoded)
      _ -> nil
    end
  end

  defp template_body(_template_data), do: nil

  defp create_input(team_id, template_name) do
    update_input(team_id, template_name)
    |> Map.put(:type, "issue")
  end

  defp update_input(team_id, template_name) do
    %{
      teamId: team_id,
      name: template_name,
      description: @default_template_description,
      templateData: %{
        title: "",
        description: @default_issue_description
      }
    }
  end

  defp template_name(opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> @default_template_name
    end
  end

  defp update_existing?(opts), do: Keyword.get(opts, :update_existing, true) == true
end
