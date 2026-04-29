defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.LinearLabelInstaller
  alias SymphonyElixir.LinearTemplateInstaller
  alias SymphonyElixir.LinearViewInstaller
  alias SymphonyElixir.LinearWorkflowStateInstaller
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Project

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @projects_query """
  query SymphonyBootstrapProjects($first: Int!) {
    projects(first: $first) {
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

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec list_projects() :: {:ok, [Project.t()]} | {:error, term()}
  def list_projects do
    case client_module().graphql(@projects_query, %{first: 100}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
        {:ok, nodes |> Enum.map(&normalize_project/1) |> Enum.reject(&is_nil/1) |> Enum.sort_by(&project_sort_key/1)}

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_projects_unexpected_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec bootstrap_env_entries([Project.t()], keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def bootstrap_env_entries(projects, opts) when is_list(projects) and is_list(opts) do
    entries =
      %{}
      |> maybe_put_existing_env("LINEAR_API_KEY")
      |> put_project_entries(projects)
      |> maybe_put("LINEAR_ASSIGNEE", Keyword.get(opts, :assignee, "me"))

    {:ok, entries}
  end

  @spec install_issue_templates(keyword()) :: {:ok, [Tracker.TemplateInstallation.t()]} | {:error, term()}
  def install_issue_templates(opts) when is_list(opts) do
    LinearTemplateInstaller.install_for_current_workflow(opts)
  end

  @spec install_labels(keyword()) :: {:ok, [Tracker.LabelInstallation.t()]} | {:error, term()}
  def install_labels(opts) when is_list(opts) do
    LinearLabelInstaller.install_for_current_workflow(opts)
  end

  @spec install_workflow_states(keyword()) :: {:ok, [Tracker.WorkflowStateInstallation.t()]} | {:error, term()}
  def install_workflow_states(opts) when is_list(opts) do
    LinearWorkflowStateInstaller.install_for_current_workflow(opts)
  end

  @spec install_views(keyword()) :: {:ok, [Tracker.ViewInstallation.t()]} | {:error, term()}
  def install_views(opts) when is_list(opts) do
    LinearViewInstaller.install_for_current_workflow(opts)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp normalize_project(%{"slugId" => slug} = project) when is_binary(slug) and slug != "" do
    team = project |> get_in(["teams", "nodes"]) |> first_team()

    %Project{
      id: project["id"],
      name: project["name"],
      slug: slug,
      url: project["url"],
      team_id: team && team["id"],
      team_key: team && team["key"],
      team_name: team && team["name"],
      metadata: %{provider: :linear, raw: project, team: team}
    }
  end

  defp normalize_project(_project), do: nil

  defp first_team([team | _]) when is_map(team), do: team
  defp first_team(_teams), do: nil

  defp project_sort_key(project), do: {String.downcase(project.name || ""), project.slug}

  defp maybe_put_existing_env(entries, key) do
    maybe_put(entries, key, normalize_env(System.get_env(key)))
  end

  defp put_project_entries(entries, [project]) do
    entries
    |> Map.put("LINEAR_PROJECT_SLUG", project.slug)
    |> Map.put("LINEAR_PROJECT_SLUGS", "")
  end

  defp put_project_entries(entries, projects) do
    entries
    |> Map.put("LINEAR_PROJECT_SLUG", "")
    |> Map.put("LINEAR_PROJECT_SLUGS", Enum.map_join(projects, ",", & &1.slug))
  end

  defp maybe_put(entries, _key, nil), do: entries
  defp maybe_put(entries, _key, ""), do: entries
  defp maybe_put(entries, key, value), do: Map.put(entries, key, to_string(value))

  defp normalize_env(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_env(_value), do: nil

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
