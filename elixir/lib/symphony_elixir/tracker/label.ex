defmodule SymphonyElixir.Tracker.Label do
  @moduledoc """
  Provider-neutral tracker label identity.
  """

  defstruct [
    :id,
    :name,
    :description,
    :color,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          color: String.t() | nil,
          metadata: map()
        }
end
