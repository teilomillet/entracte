defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.{Issue, LabelInstallation, Project, TemplateInstallation, ViewInstallation}

  @callback fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback list_projects() :: {:ok, [Project.t()]} | {:error, term()}
  @callback bootstrap_env_entries([Project.t()], keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback install_labels(keyword()) :: {:ok, [LabelInstallation.t()]} | {:error, term()}
  @callback install_issue_templates(keyword()) :: {:ok, [TemplateInstallation.t()]} | {:error, term()}
  @callback install_views(keyword()) :: {:ok, [ViewInstallation.t()]} | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec list_projects() :: {:ok, [Project.t()]} | {:error, term()}
  def list_projects do
    adapter().list_projects()
  end

  @spec bootstrap_env_entries([Project.t()], keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def bootstrap_env_entries(projects, opts \\ []) when is_list(projects) and is_list(opts) do
    adapter().bootstrap_env_entries(projects, opts)
  end

  @spec install_labels(keyword()) :: {:ok, [LabelInstallation.t()]} | {:error, term()}
  def install_labels(opts \\ []) when is_list(opts) do
    adapter().install_labels(opts)
  end

  @spec install_issue_templates(keyword()) :: {:ok, [TemplateInstallation.t()]} | {:error, term()}
  def install_issue_templates(opts \\ []) when is_list(opts) do
    adapter().install_issue_templates(opts)
  end

  @spec install_views(keyword()) :: {:ok, [ViewInstallation.t()]} | {:error, term()}
  def install_views(opts \\ []) when is_list(opts) do
    adapter().install_views(opts)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.Memory
      _ -> SymphonyElixir.Linear.Adapter
    end
  end
end
