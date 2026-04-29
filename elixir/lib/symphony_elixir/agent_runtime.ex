defmodule SymphonyElixir.AgentRuntime do
  @moduledoc false

  alias SymphonyElixir.AgentRuntime.Headless
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Config

  @type session :: AppServer.session() | Headless.session()

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Config.agent_runner() do
      :app_server ->
        with {:ok, session} <- AppServer.start_session(workspace, opts) do
          {:ok, Map.put(session, :agent_runtime, :app_server)}
        end

      :headless ->
        Headless.start_session(workspace, opts)

      :unsupported ->
        {:error, {:unsupported_agent_runner, Config.settings!().agent.runner}}
    end
  end

  @spec run_turn(session() | map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    do_run_turn(session, prompt, issue, opts)
  end

  defp do_run_turn(
         %{
           agent_runtime: :app_server,
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
    session
    |> Map.delete(:agent_runtime)
    |> AppServer.run_turn(prompt, issue, opts)
  end

  defp do_run_turn(%{agent_runtime: :app_server}, _prompt, _issue, _opts) do
    {:error, :invalid_app_server_session}
  end

  defp do_run_turn(%{agent_runtime: :headless} = session, prompt, issue, opts) do
    Headless.run_turn(session, prompt, issue, opts)
  end

  defp do_run_turn(%{agent_runtime: runtime}, _prompt, _issue, _opts) do
    {:error, {:unsupported_agent_runtime, runtime}}
  end

  defp do_run_turn(_session, _prompt, _issue, _opts) do
    {:error, :missing_agent_runtime}
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{agent_runtime: :headless}), do: :ok
  def stop_session(session), do: AppServer.stop_session(session)
end
