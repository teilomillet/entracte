defmodule SymphonyElixir.Tracker.Project do
  @moduledoc """
  Provider-neutral tracker project identity.

  Adapters may use this when exposing project discovery or bootstrap flows
  without leaking provider-specific project payloads into caller code.
  """

  defstruct [
    :id,
    :name,
    :slug,
    :key,
    :url,
    :team_id,
    :team_key,
    :team_name,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          key: String.t() | nil,
          url: String.t() | nil,
          team_id: String.t() | nil,
          team_key: String.t() | nil,
          team_name: String.t() | nil,
          metadata: map()
        }
end
