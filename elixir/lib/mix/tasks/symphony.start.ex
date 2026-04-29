defmodule Mix.Tasks.Symphony.Start do
  use Mix.Task

  alias Mix.Tasks.Symphony.TrackerLabel.Install, as: TrackerLabelInstall
  alias Mix.Tasks.Symphony.TrackerTemplate.Install, as: TrackerTemplateInstall
  alias SymphonyElixir.{CLI, EnvFile, StartCommand, TrackerLabelInstaller, TrackerTemplateInstaller}

  @moduledoc """
  Starts a local Symphony runner with safe defaults.

      mix symphony.start
      mix symphony.start --profile entracte
      mix symphony.start --port 4001
      mix symphony.start --workflow /path/to/WORKFLOW.md
      mix symphony.start --env-file /path/to/runner.env
      mix symphony.start --skip-label-install
      mix symphony.start --skip-template-install

  Profiles load `.env.<profile>` and default logs to `log/<profile>`. If `.env` defines
  `SYMPHONY_PROFILES=entracte,client-a`, running `mix symphony.start` launches those profiles as
  separate OS processes from the same checkout.
  """

  @shortdoc "Starts the Symphony runner without the long guardrails flag"
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/
  @switches [
    profile: :string,
    workflow: :string,
    env_file: :string,
    logs_root: :string,
    port: :integer,
    skip_label_install: :boolean,
    skip_template_install: :boolean
  ]
  @dialyzer {:no_return, run: 1}

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.start [--profile name] [--port port] [--workflow path] [--env-file path] [--logs-root path] [--skip-label-install] [--skip-template-install]")
    end

    result =
      with :ok <- maybe_preload_launcher_env(opts),
           {:ok, profiles} <- configured_profiles(opts) do
        case profiles do
          [] -> start_single_runner(opts)
          profiles -> start_profile_group(profiles, opts)
        end
      end

    case result do
      {:error, message} when is_binary(message) -> Mix.raise(message)
      other -> other
    end
  end

  defp start_single_runner(opts) do
    with {:ok, cli_args} <- StartCommand.cli_args(opts),
         :ok <- ensure_tracker_labels(opts),
         :ok <- ensure_tracker_templates(opts),
         :ok <- CLI.evaluate(cli_args) do
      Mix.shell().info("Symphony runner started. Press Ctrl-C to stop.")
      CLI.wait_for_shutdown()
    end
  end

  defp maybe_preload_launcher_env(opts) do
    if Keyword.has_key?(opts, :profile) do
      :ok
    else
      load_launcher_env(opts)
    end
  end

  defp load_launcher_env(opts) do
    case Keyword.get(opts, :env_file) do
      env_file when is_binary(env_file) and env_file != "" ->
        env_file
        |> Path.expand()
        |> EnvFile.load()
        |> format_launcher_env_error(env_file)

      env_file when is_binary(env_file) ->
        {:error, "env file must not be blank"}

      _ ->
        opts
        |> launcher_workflow_path()
        |> Path.dirname()
        |> Path.join(".env")
        |> EnvFile.load_if_present()
        |> format_launcher_env_error(".env")
    end
  end

  defp launcher_workflow_path(opts) do
    case Keyword.get(opts, :workflow) || System.get_env("SYMPHONY_WORKFLOW") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand("WORKFLOW.md")
    end
  end

  defp format_launcher_env_error(:ok, _path), do: :ok
  defp format_launcher_env_error({:error, reason}, path), do: {:error, "failed to load #{path}: #{inspect(reason)}"}

  defp configured_profiles(opts) do
    if Keyword.has_key?(opts, :profile) do
      {:ok, []}
    else
      "SYMPHONY_PROFILES"
      |> System.get_env()
      |> parse_profiles()
    end
  end

  defp parse_profiles(nil), do: {:ok, []}
  defp parse_profiles(""), do: {:ok, []}

  defp parse_profiles(raw_profiles) when is_binary(raw_profiles) do
    profiles =
      raw_profiles
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case Enum.find(profiles, &(not Regex.match?(@profile_pattern, &1))) do
      nil -> {:ok, profiles}
      invalid -> {:error, "invalid profile #{inspect(invalid)} in SYMPHONY_PROFILES"}
    end
  end

  defp start_profile_group(profiles, opts) do
    with {:ok, command} <- profile_command(),
         {:ok, runners} <- start_profile_runners(profiles, opts, command) do
      Mix.shell().info("Started Symphony profiles: #{Enum.join(profiles, ", ")}")
      Mix.shell().info("Each profile writes process output to log/<profile>/process.log. Press Ctrl-C to stop all profiles.")
      wait_for_profile_runners(runners)
    end
  end

  defp profile_command do
    with mix when is_binary(mix) <- System.find_executable("mix"),
         env when is_binary(env) <- System.find_executable("env") do
      {:ok, %{mix: mix, env: env}}
    else
      _ -> {:error, "could not find mix and env executables on PATH"}
    end
  end

  defp start_profile_runners(profiles, opts, command) do
    profiles
    |> Enum.reduce_while({:ok, []}, fn profile, {:ok, runners} ->
      case start_profile_runner(profile, opts, command) do
        {:ok, runner} -> {:cont, {:ok, [runner | runners]}}
        {:error, reason} -> close_started_profile_runners(reason, runners)
      end
    end)
    |> case do
      {:ok, runners} -> {:ok, Enum.reverse(runners)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_started_profile_runners(reason, runners) do
    close_profile_runners(runners)
    {:halt, {:error, reason}}
  end

  defp start_profile_runner(profile, opts, command) do
    log_path = profile_process_log_path(profile)

    with :ok <- File.mkdir_p(Path.dirname(log_path)),
         {:ok, log_device} <- File.open(log_path, [:append, :binary]) do
      args = profile_process_args(command.mix, profile, opts)

      port =
        Port.open({:spawn_executable, command.env}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args},
          {:cd, File.cwd!()}
        ])

      {:ok, %{profile: profile, port: port, log_device: log_device, log_path: log_path}}
    else
      {:error, reason} -> {:error, "failed to start profile #{profile}: #{inspect(reason)}"}
    end
  end

  defp profile_process_args(mix, profile, opts) do
    ["SYMPHONY_PROFILES=", "SYMPHONY_TERMINAL_DASHBOARD=false", mix, "symphony.start", "--profile", profile]
    |> maybe_append("--workflow", Keyword.get(opts, :workflow))
    |> maybe_append_flag("--skip-label-install", Keyword.get(opts, :skip_label_install, false))
    |> maybe_append_flag("--skip-template-install", Keyword.get(opts, :skip_template_install, false))
  end

  defp profile_process_log_path(profile), do: Path.join(["log", profile, "process.log"])

  defp wait_for_profile_runners(runners) do
    receive do
      {port, {:data, data}} ->
        runners
        |> runner_for_port(port)
        |> write_profile_output(data)

        wait_for_profile_runners(runners)

      {port, {:exit_status, status}} ->
        handle_profile_exit(port, status, runners)
    end
  end

  defp runner_for_port(runners, port), do: Enum.find(runners, &(&1.port == port))

  defp write_profile_output(nil, _data), do: :ok

  defp write_profile_output(runner, data) do
    IO.binwrite(runner.log_device, data)
  end

  defp handle_profile_exit(port, status, runners) do
    case runner_for_port(runners, port) do
      nil ->
        wait_for_profile_runners(runners)

      runner ->
        File.close(runner.log_device)
        remaining = Enum.reject(runners, &(&1.port == port))

        case {status, remaining} do
          {0, []} ->
            System.halt(0)

          {0, remaining} ->
            Mix.shell().info("Symphony profile #{runner.profile} stopped normally")
            wait_for_profile_runners(remaining)

          {status, _remaining} ->
            close_profile_runners(remaining)
            Mix.raise("Symphony profile #{runner.profile} exited with status #{status}; see #{runner.log_path}")
        end
    end
  end

  defp close_profile_runners(runners) do
    Enum.each(runners, fn runner ->
      Port.close(runner.port)
      File.close(runner.log_device)
    end)
  end

  defp ensure_tracker_labels(opts) do
    case Keyword.get(opts, :skip_label_install, false) do
      true -> :ok
      false -> install_missing_tracker_labels(opts)
    end
  end

  defp install_missing_tracker_labels(opts) do
    opts
    |> Keyword.put(:update_existing, false)
    |> TrackerLabelInstaller.install()
    |> case do
      {:ok, results} ->
        Enum.each(results, fn result ->
          Mix.shell().info(TrackerLabelInstall.format_result(result))
        end)

        :ok

      {:error, reason} ->
        Mix.shell().error("Tracker label check failed; continuing runner start: #{inspect(reason)}")
        :ok
    end
  end

  defp ensure_tracker_templates(opts) do
    case Keyword.get(opts, :skip_template_install, false) do
      true -> :ok
      false -> install_missing_tracker_templates(opts)
    end
  end

  defp install_missing_tracker_templates(opts) do
    opts
    |> Keyword.put(:update_existing, false)
    |> TrackerTemplateInstaller.install()
    |> case do
      {:ok, results} ->
        Enum.each(results, fn result ->
          Mix.shell().info(TrackerTemplateInstall.format_result(result))
        end)

        :ok

      {:error, reason} ->
        Mix.shell().error("Tracker issue template check failed; continuing runner start: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_append(args, _switch, nil), do: args
  defp maybe_append(args, _switch, ""), do: args
  defp maybe_append(args, switch, value), do: args ++ [switch, value]

  defp maybe_append_flag(args, _switch, false), do: args
  defp maybe_append_flag(args, switch, true), do: args ++ [switch]
end
