defmodule SymphonyElixir.Tracker.TemplateInstallation do
  @moduledoc """
  Provider-neutral result for tracker issue template setup.
  """

  alias SymphonyElixir.Tracker.{IssueTemplate, Project}

  @type action :: :created | :updated | :unchanged

  defstruct [
    :action,
    :template,
    projects: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          action: action(),
          template: IssueTemplate.t(),
          projects: [Project.t()],
          context: map()
        }
end
