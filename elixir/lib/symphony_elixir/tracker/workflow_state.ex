defmodule SymphonyElixir.Tracker.WorkflowState do
  @moduledoc """
  Provider-neutral tracker workflow state identity.
  """

  defstruct [
    :id,
    :name,
    :type,
    :color,
    :description,
    :position,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          type: String.t() | nil,
          color: String.t() | nil,
          description: String.t() | nil,
          position: number() | nil,
          metadata: map()
        }
end
