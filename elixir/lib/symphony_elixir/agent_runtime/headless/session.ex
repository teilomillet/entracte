defmodule SymphonyElixir.AgentRuntime.Headless.Session do
  @moduledoc """
  Explicit session contract for the headless agent runtime.

  `SymphonyElixir.AgentRuntime` dispatches headless turns by matching this
  struct, not by accepting arbitrary maps tagged with `:headless`. The fields
  are owned by the headless runtime because they describe command launch,
  timeout, workspace, and optional SSH execution state.
  """

  @enforce_keys [:command, :timeout_ms, :workspace]
  defstruct command: nil,
            timeout_ms: nil,
            worker_host: nil,
            workspace: nil

  @type t :: %__MODULE__{
          command: String.t(),
          timeout_ms: non_neg_integer(),
          worker_host: String.t() | nil,
          workspace: Path.t()
        }
end
