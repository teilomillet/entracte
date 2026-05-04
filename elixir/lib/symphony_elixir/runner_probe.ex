defmodule SymphonyElixir.RunnerProbe do
  @moduledoc """
  Detects an already-running local Symphony dashboard.
  """

  @type deps :: %{
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:get) => (String.t() -> {:ok, map()} | {:error, term()})
        }

  @spec dashboard_running?(non_neg_integer()) :: boolean()
  def dashboard_running?(port), do: dashboard_running?(port, runtime_deps())

  @spec dashboard_running?(non_neg_integer(), deps()) :: boolean()
  def dashboard_running?(port, deps) when is_integer(port) and port > 0 and is_map(deps) do
    with {:ok, _apps} <- deps.ensure_req_started.(),
         {:ok, %{status: 200, body: body}} <- deps.get.(state_url(port)) do
      state_payload?(body)
    else
      _ -> false
    end
  end

  def dashboard_running?(_port, _deps), do: false

  @spec fetch_state(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def fetch_state(port), do: fetch_state(port, runtime_deps())

  @spec fetch_state(non_neg_integer(), deps()) :: {:ok, map()} | {:error, term()}
  def fetch_state(port, deps) when is_integer(port) and port > 0 and is_map(deps) do
    with {:ok, _apps} <- deps.ensure_req_started.(),
         {:ok, %{status: 200, body: body}} <- deps.get.(state_url(port)),
         true <- state_payload?(body) do
      {:ok, body}
    else
      false -> {:error, :unexpected_dashboard_payload}
      {:ok, %{status: status}} -> {:error, {:dashboard_http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_state(_port, _deps), do: {:error, :invalid_dashboard_port}

  @spec dashboard_url(non_neg_integer()) :: String.t()
  def dashboard_url(port) when is_integer(port) and port > 0 do
    "http://127.0.0.1:#{port}"
  end

  defp runtime_deps do
    %{
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      get: fn url ->
        Req.get(url,
          connect_options: [timeout: 1_000],
          receive_timeout: 1_000
        )
      end
    }
  end

  defp state_url(port), do: dashboard_url(port) <> "/api/v1/state"

  defp state_payload?(%{"running" => running, "retrying" => retrying})
       when is_list(running) and is_list(retrying),
       do: true

  defp state_payload?(_body), do: false
end
