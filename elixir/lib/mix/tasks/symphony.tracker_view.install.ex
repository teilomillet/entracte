defmodule Mix.Tasks.Symphony.TrackerView.Install do
  use Mix.Task

  alias SymphonyElixir.Tracker.ViewInstallation
  alias SymphonyElixir.TrackerViewInstaller

  @moduledoc """
  Installs or updates tracker saved views for Symphony-runner work.

      mix symphony.tracker_view.install
      mix symphony.tracker_view.install --profile entracte
      mix symphony.tracker_view.install --workflow /path/to/WORKFLOW.md
      mix symphony.tracker_view.install --env-file /path/to/runner.env
      mix symphony.tracker_view.install --skip-favorites
  """

  @shortdoc "Installs tracker saved views used by Symphony runners"
  @switches [
    workflow: :string,
    env_file: :string,
    profile: :string,
    folder_name: :string,
    view_prefix: :string,
    skip_favorites: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.tracker_view.install [--profile name] [--workflow path-to-WORKFLOW.md] [--env-file path-to-.env] [--folder-name name] [--view-prefix prefix] [--skip-favorites]")
    end

    case TrackerViewInstaller.install(opts) do
      {:ok, results} ->
        Enum.each(results, &Mix.shell().info(format_result(&1)))
        :ok

      {:error, reason} ->
        Mix.raise("symphony.tracker_view.install failed: #{inspect(reason)}")
    end
  end

  @spec format_result(ViewInstallation.t()) :: String.t()
  def format_result(%ViewInstallation{} = result) do
    project_names = Enum.map_join(result.projects, ", ", &(&1.name || &1.slug || "unnamed project"))

    "[#{result.action}] tracker view #{inspect(result.view.name)}#{context_label(result.context)} in projects #{project_names}#{favorite_label(result.context)}"
  end

  defp context_label(%{team_key: team_key}) when is_binary(team_key) and team_key != "", do: " for team #{team_key}"
  defp context_label(%{team_name: team_name}) when is_binary(team_name) and team_name != "", do: " for team #{team_name}"
  defp context_label(_context), do: ""

  defp favorite_label(%{favorite_action: :created}), do: " (favorite created)"
  defp favorite_label(%{favorite_action: :unchanged}), do: " (favorite unchanged)"
  defp favorite_label(%{favorite_action: :skipped}), do: " (favorite skipped)"
  defp favorite_label(_context), do: ""
end
