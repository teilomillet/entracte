defmodule Mix.Tasks.Symphony.Check do
  use Mix.Task

  alias SymphonyElixir.SmokeCheck

  @moduledoc """
  Runs non-destructive checks for a local Symphony runner.

      mix symphony.check
      mix symphony.check --profile entracte
      mix symphony.check --workflow /path/to/WORKFLOW.md
      mix symphony.check --env-file /path/to/runner.env

  The check loads the local env file, validates workflow config, verifies Linear read access,
  verifies the source repository is reachable, and verifies the Codex binary is installed.
  """

  @shortdoc "Checks local Symphony runner configuration and external read access"
  @switches [workflow: :string, env_file: :string, profile: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.check [--profile name] [--workflow path-to-WORKFLOW.md] [--env-file path-to-.env]")
    end

    case SmokeCheck.run(opts) do
      {:ok, results} ->
        print_results(results)
        Mix.shell().info("symphony.check passed")
        :ok

      {:error, results} ->
        print_results(results)
        Mix.raise("symphony.check failed")
    end
  end

  defp print_results(results) do
    Enum.each(results, fn result ->
      Mix.shell().info("[#{result.status}] #{result.check}: #{result.message}")
    end)
  end
end
