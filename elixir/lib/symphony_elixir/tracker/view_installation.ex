defmodule SymphonyElixir.Tracker.ViewInstallation do
  @moduledoc """
  Provider-neutral result for tracker saved view setup.
  """

  alias SymphonyElixir.Tracker.{Project, View}

  @type action :: :created | :updated | :unchanged

  defstruct [
    :action,
    :view,
    projects: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          action: action(),
          view: View.t(),
          projects: [Project.t()],
          context: map()
        }
end
