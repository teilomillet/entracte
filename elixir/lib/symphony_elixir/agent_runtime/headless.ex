defmodule SymphonyElixir.AgentRuntime.Headless do
  @moduledoc false

  alias __MODULE__.Session
  alias SymphonyElixir.AgentRuntime.WorkspaceGuard
  alias SymphonyElixir.{Config, SSH}

  @port_line_bytes 1_048_576
  @max_output_bytes 100_000
  @max_event_text_bytes 1_000
  @max_remote_prompt_bytes 128 * 1024

  @type session :: Session.t()

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- WorkspaceGuard.validate_workspace_cwd(workspace, worker_host),
         {:ok, settings} <- Config.headless_runtime_settings() do
      {:ok,
       %Session{
         command: settings.command,
         timeout_ms: settings.timeout_ms,
         workspace: expanded_workspace,
         worker_host: worker_host
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%Session{} = session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = new_session_id()
    prompt_file = prompt_file_path(session.workspace)

    case start_port(session, prompt, prompt_file) do
      {:ok, port} ->
        metadata = port_metadata(port, session.worker_host)

        emit_message(
          on_message,
          :session_started,
          %{
            agent_runtime: "headless",
            prompt_file: prompt_file,
            session_id: session_id
          },
          metadata
        )

        deadline_ms = System.monotonic_time(:millisecond) + session.timeout_ms
        result = await_exit(port, on_message, metadata, deadline_ms, "", "")
        cleanup_prompt_file(session, prompt_file)
        handle_exit_result(result, on_message, session_id, metadata)

      {:error, reason} ->
        emit_message(on_message, :startup_failed, %{agent_runtime: "headless", reason: reason}, %{})
        {:error, reason}
    end
  end

  defp start_port(%Session{worker_host: nil} = session, prompt, prompt_file) do
    with {:ok, executable} <- bash_executable(),
         :ok <- File.write(prompt_file, prompt) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(session.command, prompt_file))],
            cd: String.to_charlist(session.workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(%Session{worker_host: worker_host} = session, prompt, prompt_file)
       when is_binary(worker_host) do
    with :ok <- validate_remote_prompt_size(prompt) do
      remote_command = remote_launch_command(session.command, session.workspace, prompt_file, prompt)
      SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
    end
  end

  defp local_launch_command(command, prompt_file) do
    [
      "export SYMPHONY_AGENT_PROMPT_FILE=#{shell_escape(prompt_file)}",
      "#{command} < #{shell_escape(prompt_file)}"
    ]
    |> Enum.join("; ")
  end

  defp remote_launch_command(command, workspace, prompt_file, prompt) do
    """
    prompt_file=#{shell_escape(prompt_file)}
    printf '%s' #{shell_escape(prompt)} > "$prompt_file"
    cd #{shell_escape(workspace)} || { status=$?; rm -f "$prompt_file"; exit $status; }
    export SYMPHONY_AGENT_PROMPT_FILE="$prompt_file"
    #{command} < "$prompt_file"
    status=$?
    rm -f "$prompt_file"
    exit $status
    """
  end

  defp validate_remote_prompt_size(prompt) when byte_size(prompt) <= @max_remote_prompt_bytes, do: :ok

  defp validate_remote_prompt_size(prompt) do
    {:error, {:remote_prompt_too_large, byte_size(prompt), @max_remote_prompt_bytes}}
  end

  defp await_exit(port, on_message, metadata, deadline_ms, pending_line, output) do
    timeout_ms = remaining_timeout_ms(deadline_ms)

    if timeout_ms == 0 do
      stop_port(port)
      {:error, :headless_timeout}
    else
      receive do
        {^port, {:data, line_data}} ->
          {pending_line, output} = record_port_output(line_data, on_message, metadata, pending_line, output)
          await_exit(port, on_message, metadata, deadline_ms, pending_line, output)

        {^port, {:exit_status, status}} ->
          {pending_line, output} = drain_port_output(port, on_message, metadata, pending_line, output)
          output = flush_pending_line(on_message, metadata, pending_line, output)

          {:ok, %{exit_status: status, output: output}}
      after
        timeout_ms ->
          stop_port(port)
          {:error, :headless_timeout}
      end
    end
  end

  defp drain_port_output(port, on_message, metadata, pending_line, output) do
    receive do
      {^port, {:data, line_data}} ->
        {pending_line, output} = record_port_output(line_data, on_message, metadata, pending_line, output)
        drain_port_output(port, on_message, metadata, pending_line, output)
    after
      0 ->
        {pending_line, output}
    end
  end

  defp record_port_output({:eol, chunk}, on_message, metadata, pending_line, output) do
    text = pending_line <> to_string(chunk) <> "\n"
    emit_headless_output(on_message, text, metadata)
    {"", append_output(output, text)}
  end

  defp record_port_output({:noeol, chunk}, _on_message, _metadata, pending_line, output) do
    {pending_line <> to_string(chunk), output}
  end

  defp flush_pending_line(_on_message, _metadata, "", output), do: output

  defp flush_pending_line(on_message, metadata, pending_line, output) do
    emit_headless_output(on_message, pending_line, metadata)
    append_output(output, pending_line)
  end

  defp remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp handle_exit_result({:ok, %{exit_status: 0} = result}, on_message, session_id, metadata) do
    emit_message(
      on_message,
      :turn_completed,
      %{
        payload: %{"exit_status" => 0, "method" => "headless/completed"},
        raw: result.output,
        session_id: session_id
      },
      metadata
    )

    {:ok,
     %{
       exit_status: 0,
       output: result.output,
       result: :turn_completed,
       session_id: session_id,
       thread_id: nil,
       turn_id: session_id
     }}
  end

  defp handle_exit_result({:ok, %{exit_status: status} = result}, on_message, session_id, metadata) do
    reason = {:headless_exit, status}

    emit_message(
      on_message,
      :turn_ended_with_error,
      %{
        payload: %{"error" => inspect(reason), "exit_status" => status, "method" => "headless/failed"},
        raw: result.output,
        reason: reason,
        session_id: session_id
      },
      metadata
    )

    {:error, reason}
  end

  defp handle_exit_result({:error, reason}, on_message, session_id, metadata) do
    emit_message(
      on_message,
      :turn_ended_with_error,
      %{
        payload: %{"error" => inspect(reason), "method" => "headless/failed"},
        reason: reason,
        session_id: session_id
      },
      metadata
    )

    {:error, reason}
  end

  defp cleanup_prompt_file(%{worker_host: nil}, prompt_file), do: File.rm(prompt_file)
  defp cleanup_prompt_file(%{worker_host: worker_host}, _prompt_file) when is_binary(worker_host), do: :ok

  defp emit_headless_output(on_message, text, metadata) do
    emit_message(
      on_message,
      :headless_output,
      %{
        payload: %{
          "method" => "headless/output",
          "stream" => "stdout_stderr",
          "text" => truncate_binary(text, @max_event_text_bytes)
        },
        raw: text
      },
      metadata
    )
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp append_output(output, text) do
    (output <> text)
    |> trim_leading_bytes(@max_output_bytes)
  end

  defp trim_leading_bytes(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp trim_leading_bytes(value, max_bytes) do
    binary_part(value, byte_size(value) - max_bytes, max_bytes)
  end

  defp truncate_binary(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_binary(value, max_bytes) do
    binary_part(value, 0, max_bytes) <> "...[truncated]"
  end

  defp prompt_file_path(workspace) do
    Path.join(workspace, ".symphony-headless-prompt-#{System.unique_integer([:positive])}.md")
  end

  defp new_session_id do
    unique_id =
      [System.unique_integer([:positive, :monotonic]), System.os_time(:millisecond)]
      |> Enum.map_join("-", &Integer.to_string(&1, 36))

    "headless-" <> unique_id
  end

  @doc false
  @spec port_metadata_for_test(port(), String.t() | nil) :: map()
  def port_metadata_for_test(port, worker_host), do: port_metadata(port, worker_host)

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{agent_runtime_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp stop_port(port) do
    Port.close(port)
    :ok
  end

  defp bash_executable do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      executable -> {:ok, executable}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok
end
