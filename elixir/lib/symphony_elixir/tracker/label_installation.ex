defmodule SymphonyElixir.Tracker.LabelInstallation do
  @moduledoc """
  Provider-neutral result for tracker label setup.
  """

  alias SymphonyElixir.Tracker.{Label, Project}

  @type action :: :created | :updated | :unchanged

  defstruct [
    :action,
    :label,
    projects: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          action: action(),
          label: Label.t(),
          projects: [Project.t()],
          context: map()
        }
end
