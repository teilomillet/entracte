defmodule SymphonyElixir.StartCommand do
  @moduledoc """
  Builds the guarded Symphony CLI invocation used by the convenient Mix start task.
  """

  alias SymphonyElixir.EnvFile

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @type deps :: %{
          required(:get_env) => (String.t() -> String.t() | nil),
          required(:load_env_file) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (String.t() -> :ok | {:error, term()})
        }

  @spec cli_args(keyword(), deps()) :: {:ok, [String.t()]} | {:error, String.t()}
  def cli_args(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with {:ok, profile} <- normalize_profile(Keyword.get(opts, :profile)),
         initial_workflow <- workflow_path(opts, deps, "WORKFLOW.md"),
         {:ok, env_file} <- resolve_env_file(opts, profile),
         :ok <- preload_env(env_file, initial_workflow, deps),
         workflow <- workflow_path(opts, deps, initial_workflow),
         {:ok, port} <- resolve_port(Keyword.get(opts, :port), deps),
         logs_root <- resolve_logs_root(Keyword.get(opts, :logs_root), profile, deps) do
      {:ok, build_args(workflow, env_file, port, logs_root)}
    end
  end

  @spec ack_flag() :: String.t()
  def ack_flag, do: @ack_flag

  defp runtime_deps do
    %{
      get_env: &System.get_env/1,
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1
    }
  end

  defp normalize_profile(nil), do: {:ok, nil}

  defp normalize_profile(profile) when is_binary(profile) do
    trimmed = String.trim(profile)

    cond do
      trimmed == "" ->
        {:error, "profile must not be blank"}

      Regex.match?(@profile_pattern, trimmed) ->
        {:ok, trimmed}

      true ->
        {:error, "profile may contain only letters, numbers, underscore, dot, and dash"}
    end
  end

  defp workflow_path(opts, deps, default) do
    case Keyword.get(opts, :workflow) || deps.get_env.("SYMPHONY_WORKFLOW") do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp resolve_env_file(opts, profile) do
    case Keyword.get(opts, :env_file) do
      env_file when is_binary(env_file) and env_file != "" -> {:ok, env_file}
      env_file when is_binary(env_file) -> {:error, "env file must not be blank"}
      _ -> {:ok, profile_env_file(profile)}
    end
  end

  defp profile_env_file(nil), do: nil
  defp profile_env_file(profile), do: ".env.#{profile}"

  defp preload_env(nil, workflow, deps) do
    workflow
    |> Path.expand()
    |> Path.dirname()
    |> Path.join(".env")
    |> deps.load_env_file_if_present.()
    |> format_env_error("env file")
  end

  defp preload_env(env_file, _workflow, deps) do
    env_file
    |> Path.expand()
    |> deps.load_env_file.()
    |> format_env_error(env_file)
  end

  defp format_env_error(:ok, _path), do: :ok
  defp format_env_error({:error, reason}, path), do: {:error, "failed to load #{path}: #{inspect(reason)}"}

  defp resolve_port(port, _deps) when is_integer(port) and port >= 0, do: {:ok, port}

  defp resolve_port(nil, deps) do
    case deps.get_env.("SYMPHONY_PORT") do
      nil -> {:ok, 4000}
      "" -> {:ok, 4000}
      raw_port -> parse_port(raw_port)
    end
  end

  defp resolve_port(_port, _deps), do: {:error, "port must be a non-negative integer"}

  defp parse_port(raw_port) do
    case Integer.parse(String.trim(raw_port)) do
      {port, ""} when port >= 0 -> {:ok, port}
      _ -> {:error, "SYMPHONY_PORT must be a non-negative integer"}
    end
  end

  defp resolve_logs_root(logs_root, _profile, _deps) when is_binary(logs_root) and logs_root != "", do: logs_root
  defp resolve_logs_root(logs_root, _profile, _deps) when is_binary(logs_root), do: nil

  defp resolve_logs_root(_logs_root, profile, deps) do
    case deps.get_env.("SYMPHONY_LOGS_ROOT") do
      value when is_binary(value) and value != "" -> value
      _ -> profile_logs_root(profile)
    end
  end

  defp profile_logs_root(nil), do: nil
  defp profile_logs_root(profile), do: Path.join("log", profile)

  defp build_args(workflow, env_file, port, logs_root) do
    [@ack_flag]
    |> maybe_append("--env-file", env_file)
    |> maybe_append("--logs-root", logs_root)
    |> Kernel.++(["--port", to_string(port), workflow])
  end

  defp maybe_append(args, _switch, nil), do: args
  defp maybe_append(args, _switch, ""), do: args
  defp maybe_append(args, switch, value), do: args ++ [switch, value]
end
