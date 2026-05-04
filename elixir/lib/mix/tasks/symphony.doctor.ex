defmodule Mix.Tasks.Symphony.Doctor do
  use Mix.Task

  alias SymphonyElixir.OperatorDiagnostics

  @moduledoc """
  Explains whether a runner profile is wired to the intended tracker, repo, and runtime.

      mix symphony.doctor
      mix symphony.doctor --profile entracte
      mix symphony.doctor --workflow /path/to/WORKFLOW.md
      mix symphony.doctor --env-file /path/to/runner.env
      mix symphony.doctor --port 4000
  """

  @shortdoc "Diagnoses runner profile wiring and ticket visibility"
  @switches [workflow: :string, env_file: :string, profile: :string, port: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.doctor [--profile name] [--workflow path] [--env-file path] [--port port]")
    end

    case OperatorDiagnostics.doctor(opts) do
      {:ok, report} ->
        Mix.shell().info(OperatorDiagnostics.format_doctor(report))
        :ok

      {:error, report} ->
        Mix.shell().info(OperatorDiagnostics.format_doctor(report))
        Mix.raise("symphony.doctor found problems")
    end
  end
end
