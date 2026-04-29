defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Deprecated compatibility helpers for the old Linear issue module.

  Runtime code should use `SymphonyElixir.Tracker.Issue`.
  """

  alias SymphonyElixir.Tracker.Issue

  @type t :: Issue.t()

  @spec label_names(Issue.t()) :: [String.t()]
  defdelegate label_names(issue), to: Issue
end
