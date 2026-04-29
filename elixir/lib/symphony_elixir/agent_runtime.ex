defmodule SymphonyElixir.AgentRuntime do
  @moduledoc false

  alias SymphonyElixir.AgentRuntime.Headless
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config

  @type session :: AppServer.session() | Headless.session()
  @type rejected_session :: map() | atom() | list() | tuple()

  @legacy_app_server_session_keys AppServer.Session |> struct() |> Map.from_struct() |> Map.keys()

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Config.agent_runner() do
      :app_server ->
        AppServer.start_session(workspace, opts)

      :headless ->
        Headless.start_session(workspace, opts)

      :unsupported ->
        {:error, {:unsupported_agent_runner, Config.settings!().agent.runner}}
    end
  end

  @spec run_turn(session() | rejected_session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    do_run_turn(session, prompt, issue, opts)
  end

  defp do_run_turn(
         %AppServer.Session{
           approval_policy: _approval_policy,
           auto_approve_requests: _auto_approve_requests,
           metadata: metadata,
           port: port,
           thread_id: thread_id,
           turn_sandbox_policy: _turn_sandbox_policy,
           workspace: workspace
         } = session,
         prompt,
         issue,
         opts
       )
       when is_port(port) and is_map(metadata) and is_binary(thread_id) and is_binary(workspace) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  defp do_run_turn(%AppServer.Session{}, _prompt, _issue, _opts) do
    {:error, :invalid_app_server_session}
  end

  defp do_run_turn(
         %Headless.Session{
           command: command,
           timeout_ms: timeout_ms,
           worker_host: worker_host,
           workspace: workspace
         } = session,
         prompt,
         issue,
         opts
       )
       when is_binary(command) and is_integer(timeout_ms) and timeout_ms >= 0 and
              (is_nil(worker_host) or is_binary(worker_host)) and is_binary(workspace) do
    Headless.run_turn(session, prompt, issue, opts)
  end

  defp do_run_turn(%Headless.Session{}, _prompt, _issue, _opts) do
    {:error, :invalid_headless_session}
  end

  # Legacy map clauses preserve rejection error shapes without dispatching maps.
  defp do_run_turn(%{agent_runtime: :app_server}, _prompt, _issue, _opts) do
    {:error, :invalid_app_server_session}
  end

  defp do_run_turn(%{agent_runtime: :headless}, _prompt, _issue, _opts) do
    {:error, :invalid_headless_session}
  end

  defp do_run_turn(%{agent_runtime: runtime}, _prompt, _issue, _opts) do
    {:error, {:unsupported_agent_runtime, runtime}}
  end

  defp do_run_turn(%{}, _prompt, _issue, _opts) do
    {:error, :missing_agent_runtime}
  end

  defp do_run_turn(session, _prompt, _issue, _opts) when is_atom(session) or is_list(session) or is_tuple(session) do
    {:error, :invalid_agent_runtime_session}
  end

  @spec stop_session(session() | map()) :: :ok
  def stop_session(%Headless.Session{}), do: :ok
  def stop_session(%{agent_runtime: :headless}), do: :ok
  def stop_session(%AppServer.Session{} = session), do: AppServer.stop_session(session)

  def stop_session(%{agent_runtime: :app_server, port: port} = session) when is_port(port) do
    # Legacy maps may carry obsolete keys; keep only the app-server session fields needed for shutdown.
    session
    |> Map.delete(:agent_runtime)
    |> Map.take(@legacy_app_server_session_keys)
    |> then(&struct(AppServer.Session, &1))
    |> AppServer.stop_session()
  end

  def stop_session(%{agent_runtime: :app_server}), do: :ok
end
