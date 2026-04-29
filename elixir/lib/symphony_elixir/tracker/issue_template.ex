defmodule SymphonyElixir.Tracker.IssueTemplate do
  @moduledoc """
  Provider-neutral issue template identity.

  This keeps template/bootstrap concepts separate from Linear so another
  tracker provider can expose equivalent setup operations later.
  """

  defstruct [
    :id,
    :name,
    :description,
    :body,
    :url,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          body: String.t() | nil,
          url: String.t() | nil,
          metadata: map()
        }
end
