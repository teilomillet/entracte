defmodule Mix.Tasks.Symphony.Bootstrap do
  use Mix.Task

  alias Mix.Tasks.Symphony.TrackerLabel.Install, as: TrackerLabelInstall
  alias Mix.Tasks.Symphony.TrackerTemplate.Install, as: TrackerTemplateInstall
  alias Mix.Tasks.Symphony.TrackerView.Install, as: TrackerViewInstall
  alias SymphonyElixir.Bootstrap
  alias SymphonyElixir.Tracker.LabelInstallation
  alias SymphonyElixir.Tracker.TemplateInstallation
  alias SymphonyElixir.Tracker.ViewInstallation

  @moduledoc """
  Bootstraps local Symphony config from tracker API access.

      mix symphony.bootstrap
      mix symphony.bootstrap --project entracte-abc123
      mix symphony.bootstrap --all-projects
      mix symphony.bootstrap --profile client-a --project client-a-def456

  The task loads or creates `.env`, discovers projects visible to the configured tracker, writes
  the chosen project slug, installs dispatch labels, the default tracker issue template and saved
  views, and runs the smoke check.
  """

  @shortdoc "Discovers tracker projects and writes local runner env config"
  @switches [
    workflow: :string,
    env_file: :string,
    profile: :string,
    project: :string,
    all_projects: :boolean,
    source_repo_url: :string,
    workspace_root: :string,
    assignee: :string,
    codex_bin: :string,
    port: :integer,
    skip_label_install: :boolean,
    skip_template_install: :boolean,
    skip_view_install: :boolean,
    skip_check: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise(usage())
    end

    case Bootstrap.run(opts) do
      {:ok, result} ->
        print_result(result)
        :ok

      {:error, reason} ->
        Mix.raise(format_error(reason))
    end
  end

  defp print_result(result) do
    Mix.shell().info("[ok] env file: #{result.env_file}")
    Mix.shell().info("[ok] tracker project slug(s): #{Enum.join(result.project_slugs, ", ")}")

    Enum.each(result.label_results, fn label_result ->
      Mix.shell().info(format_label_result(label_result))
    end)

    Enum.each(result.template_results, fn template_result ->
      Mix.shell().info(format_template_result(template_result))
    end)

    Enum.each(result.view_results, fn view_result ->
      Mix.shell().info(format_view_result(view_result))
    end)

    print_smoke_check(result.smoke_check)
    Mix.shell().info("symphony.bootstrap passed")
  end

  defp format_label_result(%LabelInstallation{} = result) do
    TrackerLabelInstall.format_result(result)
  end

  defp format_template_result(%TemplateInstallation{} = result) do
    TrackerTemplateInstall.format_result(result)
  end

  defp format_view_result(%ViewInstallation{} = result) do
    TrackerViewInstall.format_result(result)
  end

  defp print_smoke_check(:skipped), do: Mix.shell().info("[skip] smoke check")

  defp print_smoke_check({status, results}) when status in [:ok, :error] do
    Enum.each(results, fn result ->
      Mix.shell().info("[#{result.status}] #{result.check}: #{result.message}")
    end)
  end

  defp format_error(reason) when reason in [:missing_linear_api_key, :missing_linear_api_token] do
    "LINEAR_API_KEY is missing. Put it in .env or export it, then rerun mix symphony.bootstrap."
  end

  defp format_error(:tracker_no_projects) do
    "No tracker projects were visible to this API key. Create a project first, then rerun mix symphony.bootstrap."
  end

  defp format_error({:multiple_tracker_projects, projects}) do
    """
    Multiple tracker projects are visible. Pick one explicitly:

    #{format_project_choices(projects)}

    Run:
      mix symphony.bootstrap --project <slug>

    Or use every visible project in this runner:
      mix symphony.bootstrap --all-projects
    """
    |> String.trim()
  end

  defp format_error({:tracker_project_not_found, slug, projects}) do
    """
    Tracker project slug #{inspect(slug)} was not found. Visible projects:

    #{format_project_choices(projects)}
    """
    |> String.trim()
  end

  defp format_error(reason), do: "symphony.bootstrap failed: #{inspect(reason)}"

  defp format_project_choices(projects) do
    Enum.map_join(projects, "\n", fn project ->
      "- #{project.name || "Unnamed"}: #{project.slug}"
    end)
  end

  defp usage do
    "Usage: mix symphony.bootstrap [--project slug | --all-projects] [--profile name] [--workflow path] [--env-file path] [--source-repo-url url] [--workspace-root path] [--port port] [--skip-label-install] [--skip-template-install] [--skip-view-install] [--skip-check]"
  end
end
