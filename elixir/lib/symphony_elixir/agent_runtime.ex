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

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    case session do
      %{agent_runtime: :headless} -> Headless.run_turn(session, prompt, issue, opts)
      _ -> AppServer.run_turn(session, prompt, issue, opts)
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{agent_runtime: :headless}), do: :ok
  def stop_session(session), do: AppServer.stop_session(session)
end
