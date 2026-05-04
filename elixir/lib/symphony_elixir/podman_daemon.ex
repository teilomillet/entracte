defmodule SymphonyElixir.PodmanDaemon do
  @moduledoc """
  Podman-backed daemon control for local Entr'acte runners.

  This module only owns container lifecycle. The orchestrator still owns ticket
  dispatch, retries, cleanup, and observability after `symphony.start` is
  running inside the container.
  """

  alias SymphonyElixir.{OperatorDiagnostics, RunnerProbe, SecretRedactor}

  @default_image "localhost/entracte-runner:latest"
  @container_prefix "entracte"
  @default_stop_timeout_seconds 30

  @type command_result :: {String.t(), non_neg_integer()}
  @type context :: OperatorDiagnostics.context()
  @type lifecycle_result :: {:ok, map()} | {:error, String.t()}
  @type deps :: %{
          required(:find_executable) => (String.t() -> String.t() | nil),
          required(:cmd) => (String.t(), [String.t()], keyword() -> command_result()),
          required(:prepare) => (keyword() -> {:ok, context()} | {:error, String.t()}),
          required(:dashboard_running?) => (non_neg_integer() -> boolean()),
          required(:cwd) => (-> Path.t()),
          required(:get_env) => (String.t() -> String.t() | nil),
          required(:file_dir?) => (Path.t() -> boolean()),
          required(:file_regular?) => (Path.t() -> boolean())
        }

  @spec start(keyword(), deps()) :: lifecycle_result()
  def start(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with {:ok, context} <- deps.prepare.(opts),
         :ok <- ensure_podman(deps),
         :ok <- ensure_dashboard_port_available(context, opts, deps),
         {:ok, args, metadata} <- start_args(context, opts, deps),
         {output, 0} <- deps.cmd.("podman", args, stderr_to_stdout: true) do
      {:ok, Map.put(metadata, :container_id, String.trim(output))}
    else
      {output, status} when is_integer(status) -> {:error, "podman run failed with exit #{status}: #{redact(output)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect_redacted(reason)}
    end
  end

  @spec stop(keyword(), deps()) :: lifecycle_result()
  def stop(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with :ok <- ensure_podman(deps),
         {:ok, name} <- container_name(opts, deps),
         {output, 0} <- deps.cmd.("podman", ["stop", "--time", to_string(stop_timeout(opts)), name], stderr_to_stdout: true) do
      {:ok, %{name: name, output: String.trim(output)}}
    else
      {output, status} when is_integer(status) -> {:error, "podman stop failed with exit #{status}: #{redact(output)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect_redacted(reason)}
    end
  end

  @spec status(keyword(), deps()) :: lifecycle_result()
  def status(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with :ok <- ensure_podman(deps),
         {:ok, name} <- container_name(opts, deps),
         {output, 0} <-
           deps.cmd.("podman", ["inspect", "--format", "{{.Name}} {{.State.Status}}", name], stderr_to_stdout: true) do
      {:ok, %{name: name, status: String.trim(output)}}
    else
      {output, status} when is_integer(status) -> {:error, "podman inspect failed with exit #{status}: #{redact(output)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect_redacted(reason)}
    end
  end

  @spec logs(keyword(), deps()) :: lifecycle_result()
  def logs(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with :ok <- ensure_podman(deps),
         {:ok, name} <- container_name(opts, deps),
         {output, 0} <- deps.cmd.("podman", ["logs", "--tail", to_string(log_tail(opts)), name], stderr_to_stdout: true) do
      {:ok, %{name: name, logs: output}}
    else
      {output, status} when is_integer(status) -> {:error, "podman logs failed with exit #{status}: #{redact(output)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect_redacted(reason)}
    end
  end

  @spec build(keyword(), deps()) :: lifecycle_result()
  def build(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with :ok <- ensure_podman(deps),
         {:ok, containerfile} <- containerfile_path(opts, deps),
         {output, 0} <-
           deps.cmd.(
             "podman",
             ["build", "--file", containerfile, "--tag", image(opts), repo_root(opts, deps)],
             stderr_to_stdout: true
           ) do
      {:ok, %{image: image(opts), output: output}}
    else
      {output, status} when is_integer(status) -> {:error, "podman build failed with exit #{status}: #{redact(output)}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect_redacted(reason)}
    end
  end

  @doc false
  @spec start_args_for_test(context(), keyword(), deps()) :: {:ok, [String.t()], map()} | {:error, String.t()}
  def start_args_for_test(context, opts, deps), do: start_args(context, opts, deps)

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      find_executable: &System.find_executable/1,
      cmd: fn command, args, opts -> System.cmd(command, args, opts) end,
      prepare: &OperatorDiagnostics.prepare/1,
      dashboard_running?: &RunnerProbe.dashboard_running?/1,
      cwd: &File.cwd!/0,
      get_env: &System.get_env/1,
      file_dir?: &File.dir?/1,
      file_regular?: &File.regular?/1
    }
  end

  defp start_args(%{port: port} = context, opts, deps) do
    name = normalized_container_name(opts)
    repo_root = repo_root(opts, deps)
    elixir_dir = Path.join(repo_root, "elixir")
    env_file = context.env_file_path
    logs_root = logs_root(opts, context)
    workspace_root = context.settings.workspace.root |> to_string() |> Path.expand()
    mounted_roots = [repo_root, workspace_root, logs_root] |> Enum.reject(&is_nil/1) |> Enum.map(&Path.expand/1)

    args =
      [
        "run",
        "--detach",
        "--replace",
        "--name",
        name,
        "--label",
        "org.entracte.runner=true",
        "--label",
        "org.entracte.profile=#{daemon_label(opts)}",
        "--publish",
        "127.0.0.1:#{port}:#{port}",
        "--workdir",
        elixir_dir,
        "--volume",
        "#{repo_root}:#{repo_root}:rw",
        "--volume",
        "#{workspace_root}:#{workspace_root}:rw"
      ]
      |> maybe_append_volume(logs_root)
      |> maybe_append_path_mount(context.workflow_path, :ro, mounted_roots)
      |> maybe_append_path_mount(env_file, :ro, mounted_roots)
      |> maybe_append_env_file(env_file)
      |> maybe_append_host_auth(opts, deps)
      |> Kernel.++([image(opts), "bash", "-lc", container_command(context, logs_root)])

    {:ok, args, %{name: name, image: image(opts), port: port, logs_root: logs_root, workspace_root: workspace_root}}
  end

  defp container_command(context, logs_root) do
    [
      "mise trust",
      "mise install",
      "mise exec -- mix setup",
      "mise exec -- mix symphony.check #{runner_cli_args(context, logs_root)}",
      "exec mise exec -- mix symphony.start #{runner_cli_args(context, logs_root)}"
    ]
    |> Enum.join(" && ")
  end

  defp runner_cli_args(context, logs_root) do
    []
    |> maybe_shell_arg("--workflow", context.workflow_path)
    |> maybe_shell_arg("--env-file", context.env_file_path)
    |> maybe_shell_arg("--logs-root", logs_root)
    |> maybe_shell_arg("--port", to_string(context.port))
    |> Enum.join(" ")
  end

  defp maybe_shell_arg(args, _switch, nil), do: args
  defp maybe_shell_arg(args, _switch, ""), do: args
  defp maybe_shell_arg(args, switch, value), do: args ++ [switch, shell_quote(value)]

  defp maybe_append_volume(args, nil), do: args
  defp maybe_append_volume(args, ""), do: args
  defp maybe_append_volume(args, path), do: args ++ ["--volume", "#{Path.expand(path)}:#{Path.expand(path)}:rw"]

  defp maybe_append_path_mount(args, nil, _mode, _mounted_roots), do: args
  defp maybe_append_path_mount(args, "", _mode, _mounted_roots), do: args

  defp maybe_append_path_mount(args, path, mode, mounted_roots) do
    expanded = Path.expand(path)

    if path_covered?(expanded, mounted_roots) do
      args
    else
      args ++ ["--volume", "#{expanded}:#{expanded}:#{mode}"]
    end
  end

  defp maybe_append_env_file(args, nil), do: args
  defp maybe_append_env_file(args, ""), do: args
  defp maybe_append_env_file(args, path), do: args ++ ["--env-file", Path.expand(path)]

  defp maybe_append_host_auth(args, opts, deps) do
    if Keyword.get(opts, :mount_host_auth, false) do
      home = deps.get_env.("HOME") || System.user_home!()

      args =
        [
          Path.join(home, ".codex"),
          Path.join([home, ".config", "gh"]),
          Path.join([home, ".config", "glab"]),
          Path.join(home, ".ssh")
        ]
        |> Enum.reduce(args, fn path, acc ->
          append_host_auth_dir(acc, path, home, deps)
        end)

      [
        Path.join(home, ".gitconfig"),
        Path.join(home, ".git-credentials")
      ]
      |> Enum.reduce(args, fn path, acc ->
        append_host_auth_file(acc, path, home, deps)
      end)
    else
      args
    end
  end

  defp append_host_auth_dir(args, path, home, deps) do
    if deps.file_dir?.(path) do
      append_host_auth_mount(args, path, home)
    else
      args
    end
  end

  defp append_host_auth_file(args, path, home, deps) do
    if deps.file_regular?.(path) do
      append_host_auth_mount(args, path, home)
    else
      args
    end
  end

  defp append_host_auth_mount(args, path, home) do
    args ++ ["--volume", "#{path}:/root/#{Path.relative_to(path, home)}:ro"]
  end

  defp ensure_podman(deps) do
    case deps.find_executable.("podman") do
      nil -> {:error, "podman is not installed or not on PATH"}
      _path -> :ok
    end
  end

  defp ensure_dashboard_port_available(%{port: port}, opts, deps) do
    cond do
      Keyword.get(opts, :allow_running_dashboard, false) ->
        :ok

      port > 0 and deps.dashboard_running?.(port) ->
        {:error, "dashboard already responds on #{RunnerProbe.dashboard_url(port)}; stop that runner or choose another port"}

      true ->
        :ok
    end
  end

  defp container_name(opts, _deps) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) ->
        if String.trim(name) == "" do
          {:ok, normalized_container_name(Keyword.delete(opts, :name))}
        else
          {:ok, normalize_container_name(name)}
        end

      _ ->
        {:ok, normalized_container_name(opts)}
    end
  end

  defp normalized_container_name(opts) do
    opts
    |> Keyword.get(:name, Keyword.get(opts, :profile, "default"))
    |> normalize_container_name()
  end

  defp normalize_container_name(name) when is_binary(name) do
    suffix =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "default"
        value -> value
      end

    "#{@container_prefix}-#{suffix}"
  end

  defp daemon_label(opts) do
    opts
    |> Keyword.get(:name, Keyword.get(opts, :profile, "default"))
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
  end

  defp image(opts), do: Keyword.get(opts, :image, @default_image)

  defp logs_root(opts, _context), do: Keyword.get(opts, :logs_root) || profile_logs_root(Keyword.get(opts, :profile))

  defp profile_logs_root(profile) when is_binary(profile) and profile != "", do: Path.join("log", profile)
  defp profile_logs_root(_profile), do: nil

  defp containerfile_path(opts, deps) do
    path =
      opts
      |> Keyword.get(:containerfile, Path.join([repo_root(opts, deps), "containers", "entracte-runner.Containerfile"]))
      |> Path.expand()

    {:ok, path}
  end

  defp repo_root(opts, deps) do
    opts
    |> Keyword.get(:repo_root)
    |> case do
      nil -> deps.cwd.() |> Path.expand() |> Path.dirname()
      path -> Path.expand(path)
    end
  end

  defp stop_timeout(opts), do: Keyword.get(opts, :stop_timeout, @default_stop_timeout_seconds)
  defp log_tail(opts), do: Keyword.get(opts, :tail, 200)

  defp path_covered?(path, mounted_roots) do
    Enum.any?(mounted_roots, fn root ->
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp shell_quote(value) do
    value = to_string(value)
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp redact(value) when is_binary(value), do: SecretRedactor.redact_string(value)
  defp inspect_redacted(value), do: SecretRedactor.inspect_redacted(value)
end
