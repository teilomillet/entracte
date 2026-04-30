defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a tracked issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @default_agent_runner "app_server"

  @type app_server_runtime_settings :: %{
          command: String.t(),
          preset: String.t() | nil,
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer()
        }

  @type codex_runtime_settings :: app_server_runtime_settings()

  @type agent_runner :: :app_server | :headless | :unsupported

  @type headless_runtime_settings :: %{
          command: String.t(),
          timeout_ms: pos_integer()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec app_server_turn_sandbox_policy(Path.t() | nil) :: map()
  def app_server_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid app-server turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil), do: app_server_turn_sandbox_policy(workspace)

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @doc false
  @spec validate_settings_for_test(Schema.t()) :: :ok | {:error, term()}
  def validate_settings_for_test(settings), do: validate_semantics(settings)

  @spec agent_runner() :: agent_runner()
  def agent_runner do
    settings!()
    |> configured_agent_runner()
    |> normalize_agent_runner()
  end

  @spec app_server_command() :: String.t()
  def app_server_command do
    settings!()
    |> effective_app_server_command()
    |> case do
      {:ok, command} ->
        command

      {:error, reason} ->
        raise ArgumentError, message: "Invalid app-server command: #{inspect(reason)}"
    end
  end

  @spec app_server_turn_timeout_ms() :: pos_integer()
  def app_server_turn_timeout_ms, do: effective_runtime_value(settings!(), :turn_timeout_ms)

  @spec app_server_read_timeout_ms() :: pos_integer()
  def app_server_read_timeout_ms, do: effective_runtime_value(settings!(), :read_timeout_ms)

  @spec app_server_stall_timeout_ms() :: non_neg_integer()
  def app_server_stall_timeout_ms, do: effective_runtime_value(settings!(), :stall_timeout_ms)

  @spec app_server_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, app_server_runtime_settings()} | {:error, term()}
  def app_server_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings(),
         {:ok, command} <- effective_app_server_command(settings),
         {:ok, turn_sandbox_policy} <-
           Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         command: command,
         preset: effective_runtime_value(settings, :preset),
         approval_policy: effective_runtime_value(settings, :approval_policy),
         thread_sandbox: effective_runtime_value(settings, :thread_sandbox),
         turn_sandbox_policy: turn_sandbox_policy,
         turn_timeout_ms: effective_runtime_value(settings, :turn_timeout_ms),
         read_timeout_ms: effective_runtime_value(settings, :read_timeout_ms),
         stall_timeout_ms: effective_runtime_value(settings, :stall_timeout_ms)
       }}
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    app_server_runtime_settings(workspace, opts)
  end

  @spec headless_runtime_settings() :: {:ok, headless_runtime_settings()} | {:error, term()}
  def headless_runtime_settings do
    with {:ok, settings} <- settings() do
      headless_runtime_settings(settings)
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_tracker_semantics(settings.tracker) do
      validate_agent_runtime_semantics(settings)
    end
  end

  defp validate_tracker_semantics(tracker) do
    cond do
      is_nil(tracker.kind) ->
        {:error, :missing_tracker_kind}

      tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, tracker.kind}}

      tracker.kind == "linear" and not is_binary(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      tracker.kind == "linear" and configured_project_slugs(tracker) == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp validate_agent_runtime_semantics(settings) do
    runner = configured_agent_runner(settings)

    case normalize_agent_runner(runner) do
      :unsupported ->
        {:error, {:unsupported_agent_runner, runner}}

      :app_server ->
        validate_app_server_runtime_settings(settings)

      :headless ->
        validate_headless_runtime_settings(settings)
    end
  end

  defp configured_agent_runner(settings) do
    agent = Map.get(settings, :agent) || Map.get(settings, "agent")

    case agent do
      %{runner: runner} when not is_nil(runner) -> runner
      %{"runner" => runner} when not is_nil(runner) -> runner
      _agent -> @default_agent_runner
    end
  end

  defp validate_app_server_runtime_settings(settings) do
    case effective_app_server_command(settings) do
      {:ok, _command} -> :ok
      {:error, _reason} -> {:error, :missing_app_server_command}
    end
  end

  defp validate_headless_runtime_settings(settings) do
    case headless_runtime_settings(settings) do
      {:ok, _settings} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp effective_app_server_command(settings) do
    case effective_runtime_value(settings, :command) do
      command when is_binary(command) and command != "" -> {:ok, command}
      _command -> {:error, :missing_app_server_command}
    end
  end

  defp effective_runtime_value(settings, field) do
    runtime = Map.get(settings, :runtime) || %{}
    codex = Map.get(settings, :codex) || %{}

    case Map.get(runtime, field) do
      nil -> Map.get(codex, field)
      value -> value
    end
  end

  defp headless_runtime_settings(settings) do
    command = settings.headless.command

    if blank?(command) do
      {:error, :missing_headless_command}
    else
      {:ok, %{command: command, timeout_ms: settings.headless.timeout_ms}}
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp normalize_agent_runner(runner) when is_binary(runner) do
    case runner |> String.trim() |> String.downcase() do
      "app_server" -> :app_server
      "codex_app_server" -> :app_server
      "headless" -> :headless
      _ -> :unsupported
    end
  end

  defp normalize_agent_runner(_runner), do: :unsupported

  defp configured_project_slugs(tracker) do
    tracker
    |> Map.get(:project_slugs, [])
    |> case do
      slugs when is_list(slugs) -> Enum.reject(slugs, &(&1 in [nil, ""]))
      _ -> []
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
