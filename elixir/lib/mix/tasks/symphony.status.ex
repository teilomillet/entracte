defmodule Mix.Tasks.Symphony.Status do
  use Mix.Task

  alias SymphonyElixir.{OperatorDiagnostics, RunnerProbe, SecretRedactor}

  @moduledoc """
  Prints local dashboard status for a runner profile.

      mix symphony.status
      mix symphony.status --profile entracte
      mix symphony.status --workflow /path/to/WORKFLOW.md
      mix symphony.status --env-file /path/to/runner.env
      mix symphony.status --port 4000
  """

  @shortdoc "Checks whether the local runner dashboard is reachable"
  @switches [workflow: :string, env_file: :string, profile: :string, logs_root: :string, port: :integer]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.status [--profile name] [--workflow path] [--env-file path] [--port port]")
    end

    with {:ok, context} <- OperatorDiagnostics.prepare(opts),
         {:ok, state} <- RunnerProbe.fetch_state(context.port) do
      Mix.shell().info(format_running_status(context.port, state))
    else
      {:error, reason} when is_binary(reason) ->
        Mix.raise(reason)

      {:error, reason} ->
        port = Keyword.get(opts, :port, 4000)
        Mix.shell().info("Runner dashboard is not reachable at #{RunnerProbe.dashboard_url(port)}: #{SecretRedactor.inspect_redacted(reason)}")
        :ok
    end
  end

  defp format_running_status(port, state) do
    running = state |> Map.get("running", []) |> length()
    retrying = state |> Map.get("retrying", []) |> length()

    [
      "Runner dashboard is reachable at #{RunnerProbe.dashboard_url(port)}",
      "running=#{running} retrying=#{retrying}"
    ]
    |> Enum.join("\n")
  end
end
