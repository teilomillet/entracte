defmodule SymphonyElixir.Tracker.WorkflowStateInstallation do
  @moduledoc """
  Provider-neutral result for tracker workflow state setup.
  """

  alias SymphonyElixir.Tracker.{Project, WorkflowState}

  @type action :: :created | :unchanged

  defstruct [
    :action,
    :state,
    projects: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          action: action(),
          state: WorkflowState.t(),
          projects: [Project.t()],
          context: map()
        }
end
