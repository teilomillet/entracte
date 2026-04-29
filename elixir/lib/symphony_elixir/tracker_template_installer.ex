defmodule SymphonyElixir.TrackerTemplateInstaller do
  @moduledoc """
  Loads runner config and asks the configured tracker adapter to install issue templates.
  """

  alias SymphonyElixir.{Config, EnvFile, Tracker, Workflow}
  alias SymphonyElixir.Tracker.TemplateInstallation

  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @type deps :: %{
          required(:load_env_file) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (String.t() -> :ok | {:error, term()}),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:validate_config) => (-> :ok | {:error, term()}),
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:install_templates) => (keyword() -> {:ok, [TemplateInstallation.t()]} | {:error, term()})
        }

  @spec install(keyword(), deps()) :: {:ok, [TemplateInstallation.t()]} | {:error, term()}
  def install(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    workflow_path = opts |> Keyword.get(:workflow, "WORKFLOW.md") |> Path.expand()

    with :ok <- load_env(opts, workflow_path, deps),
         :ok <- deps.set_workflow_file_path.(workflow_path),
         :ok <- deps.validate_config.(),
         {:ok, _apps} <- deps.ensure_req_started.() do
      deps.install_templates.(opts)
    end
  end

  defp runtime_deps do
    %{
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      validate_config: &Config.validate!/0,
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      install_templates: &Tracker.install_issue_templates/1
    }
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
end
