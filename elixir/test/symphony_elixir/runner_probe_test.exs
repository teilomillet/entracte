defmodule SymphonyElixir.RunnerProbeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RunnerProbe

  test "detects a reachable Symphony dashboard state endpoint" do
    deps = %{
      ensure_req_started: fn -> {:ok, [:req]} end,
      get: fn "http://127.0.0.1:4000/api/v1/state" ->
        {:ok, %{status: 200, body: %{"running" => [], "retrying" => []}}}
      end
    }

    assert RunnerProbe.dashboard_running?(4000, deps)
  end

  test "rejects occupied ports that are not a Symphony dashboard" do
    deps = %{
      ensure_req_started: fn -> {:ok, [:req]} end,
      get: fn _url -> {:ok, %{status: 200, body: "<html></html>"}} end
    }

    refute RunnerProbe.dashboard_running?(4000, deps)
  end

  test "treats unavailable ports as not running" do
    deps = %{
      ensure_req_started: fn -> {:ok, [:req]} end,
      get: fn _url -> {:error, :econnrefused} end
    }

    refute RunnerProbe.dashboard_running?(4000, deps)
  end

  test "ignores invalid ports before probing" do
    deps = %{
      ensure_req_started: fn -> flunk("should not start Req") end,
      get: fn _url -> flunk("should not probe") end
    }

    refute RunnerProbe.dashboard_running?(0, deps)
  end

  test "default runtime probe treats closed ports as not running" do
    refute RunnerProbe.dashboard_running?(1)
  end

  test "formats the local dashboard url" do
    assert RunnerProbe.dashboard_url(4000) == "http://127.0.0.1:4000"
  end
end
