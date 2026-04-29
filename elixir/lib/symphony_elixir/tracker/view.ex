defmodule SymphonyElixir.Tracker.View do
  @moduledoc """
  Provider-neutral tracker saved view identity.
  """

  defstruct [
    :id,
    :name,
    :description,
    :url,
    :slug,
    filters: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          url: String.t() | nil,
          slug: String.t() | nil,
          filters: map(),
          metadata: map()
        }
end
