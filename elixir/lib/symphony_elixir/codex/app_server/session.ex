defmodule SymphonyElixir.Codex.AppServer.Session do
  @moduledoc """
  Explicit session contract for the Codex app-server runtime.

  `SymphonyElixir.AgentRuntime` dispatches app-server turns by matching this
  struct, not by accepting ad hoc maps tagged with runtime atoms. Future runtime
  implementations should expose their own concrete session contracts so invalid
  or unknown maps cannot be mistaken for executable runtime sessions.
  """

  @enforce_keys [
    :approval_policy,
    :auto_approve_requests,
    :metadata,
    :port,
    :thread_id,
    :thread_sandbox,
    :turn_sandbox_policy,
    :workspace
  ]
  defstruct approval_policy: nil,
            auto_approve_requests: false,
            metadata: %{},
            port: nil,
            thread_id: nil,
            thread_sandbox: nil,
            turn_sandbox_policy: %{},
            worker_host: nil,
            workspace: nil

  @type t :: %__MODULE__{
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          metadata: map(),
          port: port(),
          thread_id: String.t(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          worker_host: String.t() | nil,
          workspace: Path.t()
        }
end
