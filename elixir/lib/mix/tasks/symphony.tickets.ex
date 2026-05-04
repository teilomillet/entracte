defmodule Mix.Tasks.Symphony.Tickets do
  use Mix.Task

  alias SymphonyElixir.OperatorDiagnostics

  @moduledoc """
  Previews active-state tracker tickets and explains dispatch gates.

      mix symphony.tickets
      mix symphony.tickets --profile entracte
      mix symphony.tickets --workflow /path/to/WORKFLOW.md
      mix symphony.tickets --env-file /path/to/runner.env
  """

  @shortdoc "Previews tickets the runner can or cannot dispatch"
  @switches [workflow: :string, env_file: :string, profile: :string]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.tickets [--profile name] [--workflow path] [--env-file path]")
    end

    case OperatorDiagnostics.ticket_preview(opts) do
      {:ok, previews} ->
        Mix.shell().info(OperatorDiagnostics.format_ticket_preview(previews))
        :ok

      {:error, reason} ->
        Mix.raise(reason)
    end
  end
end
