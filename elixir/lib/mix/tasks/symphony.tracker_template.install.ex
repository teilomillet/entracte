defmodule Mix.Tasks.Symphony.TrackerTemplate.Install do
  use Mix.Task

  alias SymphonyElixir.Tracker.TemplateInstallation
  alias SymphonyElixir.TrackerTemplateInstaller

  @moduledoc """
  Installs or updates the configured tracker issue template for Symphony-runner tasks.

      mix symphony.tracker_template.install
      mix symphony.tracker_template.install --profile entracte
      mix symphony.tracker_template.install --name "Codex Agent Task"
      mix symphony.tracker_template.install --workflow /path/to/WORKFLOW.md
      mix symphony.tracker_template.install --env-file /path/to/runner.env
  """

  @shortdoc "Installs the tracker issue template used by Symphony runners"
  @switches [workflow: :string, env_file: :string, name: :string, profile: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.tracker_template.install [--profile name] [--name template-name] [--workflow path-to-WORKFLOW.md] [--env-file path-to-.env]")
    end

    case TrackerTemplateInstaller.install(opts) do
      {:ok, results} ->
        Enum.each(results, &Mix.shell().info(format_result(&1)))
        :ok

      {:error, reason} ->
        Mix.raise("symphony.tracker_template.install failed: #{inspect(reason)}")
    end
  end

  @spec format_result(TemplateInstallation.t()) :: String.t()
  def format_result(%TemplateInstallation{} = result) do
    project_names = Enum.map_join(result.projects, ", ", &(&1.name || &1.slug || "unnamed project"))

    "[#{result.action}] tracker issue template #{inspect(result.template.name)}#{context_label(result.context)} in projects #{project_names}"
  end

  defp context_label(%{team_key: team_key}) when is_binary(team_key) and team_key != "", do: " for team #{team_key}"
  defp context_label(%{team_name: team_name}) when is_binary(team_name) and team_name != "", do: " for team #{team_name}"
  defp context_label(_context), do: ""
end
