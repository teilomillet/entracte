defmodule Mix.Tasks.Symphony.LinearTemplate.Install do
  use Mix.Task

  alias Mix.Tasks.Symphony.TrackerTemplate.Install, as: TrackerTemplateInstall
  alias SymphonyElixir.LinearTemplateInstaller

  @moduledoc """
  Installs or updates the default Linear issue template for Symphony-runner tasks.

      mix symphony.linear_template.install
      mix symphony.linear_template.install --profile entracte
      mix symphony.linear_template.install --name "Codex Agent Task"
      mix symphony.linear_template.install --workflow /path/to/WORKFLOW.md
      mix symphony.linear_template.install --env-file /path/to/runner.env

  The task resolves the configured Linear project or projects, installs the template on each
  project's team, and updates the existing template with the same name when one already exists.
  """

  @shortdoc "Installs the Linear issue template used by Symphony runners"
  @switches [workflow: :string, env_file: :string, name: :string, profile: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.linear_template.install [--profile name] [--name template-name] [--workflow path-to-WORKFLOW.md] [--env-file path-to-.env]")
    end

    case LinearTemplateInstaller.install(opts) do
      {:ok, results} ->
        Enum.each(results, &Mix.shell().info(TrackerTemplateInstall.format_result(&1)))
        :ok

      {:error, reason} ->
        Mix.raise("symphony.linear_template.install failed: #{inspect(reason)}")
    end
  end
end
