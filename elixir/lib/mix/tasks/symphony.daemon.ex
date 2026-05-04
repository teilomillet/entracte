defmodule Mix.Tasks.Symphony.Daemon do
  use Mix.Task

  alias SymphonyElixir.{PodmanDaemon, RunnerProbe}

  @shortdoc "Controls a Podman-backed Symphony runner daemon"

  @moduledoc """
  Controls a local Symphony runner in a Podman container.

      mix symphony.daemon build
      mix symphony.daemon start --workflow /path/to/WORKFLOW.md --env-file /path/to/runner.env --name anef
      mix symphony.daemon status --name anef
      mix symphony.daemon logs --name anef --tail 200
      mix symphony.daemon stop --name anef

  The daemon command only owns the container lifecycle. The runner inside the
  container still uses `symphony.check` before `symphony.start`, so the existing
  workflow, Linear, source repository, Codex, retry, and dashboard contracts stay
  in the normal code paths.
  """

  @actions ~w(build start stop status logs)
  @switches [
    profile: :string,
    workflow: :string,
    env_file: :string,
    logs_root: :string,
    port: :integer,
    name: :string,
    image: :string,
    containerfile: :string,
    repo_root: :string,
    mount_host_auth: :boolean,
    allow_running_dashboard: :boolean,
    stop_timeout: :integer,
    tail: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {action, rest} = extract_action(args)
    {opts, argv, invalid} = OptionParser.parse(rest, strict: @switches)

    if action not in @actions or argv != [] or invalid != [] do
      Mix.raise(usage())
    end

    action
    |> run_action(opts)
    |> print_result(action)
  end

  defp extract_action([arg | rest]) when arg in @actions, do: {arg, rest}
  defp extract_action(args), do: {nil, args}

  defp run_action("build", opts), do: PodmanDaemon.build(opts)
  defp run_action("start", opts), do: PodmanDaemon.start(opts)
  defp run_action("stop", opts), do: PodmanDaemon.stop(opts)
  defp run_action("status", opts), do: PodmanDaemon.status(opts)
  defp run_action("logs", opts), do: PodmanDaemon.logs(opts)

  defp print_result({:ok, result}, "build") do
    Mix.shell().info("Built Podman image #{result.image}")
  end

  defp print_result({:ok, result}, "start") do
    Mix.shell().info("Started #{result.name} with image #{result.image}")
    Mix.shell().info("Dashboard: #{RunnerProbe.dashboard_url(result.port)}")
    Mix.shell().info("Container ID: #{result.container_id}")
  end

  defp print_result({:ok, result}, "stop") do
    Mix.shell().info("Stopped #{result.name}")
  end

  defp print_result({:ok, result}, "status") do
    Mix.shell().info(result.status)
  end

  defp print_result({:ok, result}, "logs") do
    Mix.shell().info(result.logs)
  end

  defp print_result({:error, reason}, _action) when is_binary(reason), do: Mix.raise(reason)

  defp usage do
    "Usage: mix symphony.daemon <build|start|stop|status|logs> " <>
      "[--workflow path] [--env-file path] [--logs-root path] [--port port] [--name name] [--image image]"
  end
end
