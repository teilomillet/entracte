defmodule SymphonyElixir.OperatorDiagnostics do
  @moduledoc """
  Structured operator diagnostics for runner profiles.

  The functions in this module return data first and format second. That keeps
  today's Mix tasks simple while giving a future terminal console one shared
  source for profile, tracker, ticket, and dashboard state.
  """

  alias SymphonyElixir.{Config, EnvFile, RunnerProbe, SecretRedactor, SmokeCheck, Tracker, Workflow}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Tracker.{Issue, Project}

  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @linear_context_query """
  query SymphonyOperatorLinearContext {
    organization {
      name
      urlKey
    }
    teams(first: 100) {
      nodes {
        key
        name
      }
    }
  }
  """

  @viewer_query """
  query SymphonyOperatorViewer {
    viewer {
      id
      name
      email
    }
  }
  """

  @type status :: :ok | :error | :skip
  @type result :: %{required(:status) => status(), required(:check) => String.t(), required(:message) => String.t()}
  @type context :: %{
          required(:workflow_path) => Path.t(),
          required(:env_file_path) => Path.t() | nil,
          required(:env_file_status) => :loaded | :not_found | :not_configured,
          required(:settings) => Config.Schema.t(),
          required(:port) => non_neg_integer()
        }
  @type ticket_preview :: %{
          required(:status) => :ready | :skipped,
          required(:identifier) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:state) => String.t() | nil,
          required(:project) => Project.t() | nil,
          required(:url) => String.t() | nil,
          required(:labels) => [String.t()],
          required(:reasons) => [String.t()]
        }
  @type report :: %{
          required(:context) => context() | nil,
          required(:smoke_checks) => [result()],
          required(:linear_context) => map() | nil,
          required(:visible_projects) => [Project.t()],
          required(:configured_project_slugs) => [String.t()],
          required(:project_matches) => [Project.t()],
          required(:ticket_preview) => [ticket_preview()],
          required(:dashboard) => map() | nil,
          required(:errors) => [String.t()]
        }
  @type deps :: %{
          required(:file_regular?) => (Path.t() -> boolean()),
          required(:load_env_file) => (Path.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (Path.t() -> :ok | {:error, term()}),
          required(:set_workflow_file_path) => (Path.t() -> :ok | {:error, term()}),
          required(:validate_config) => (-> :ok | {:error, term()}),
          required(:settings) => (-> Config.Schema.t()),
          required(:smoke_check) => (keyword() -> {:ok, [result()]} | {:error, [result()]}),
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:list_projects) => (-> {:ok, [Project.t()]} | {:error, term()}),
          required(:fetch_issues_by_states) => ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()}),
          required(:linear_graphql) => (String.t(), map() -> {:ok, map()} | {:error, term()}),
          required(:dashboard_running?) => (non_neg_integer() -> boolean())
        }

  @spec prepare(keyword(), deps()) :: {:ok, context()} | {:error, String.t()}
  def prepare(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    workflow_path = opts |> Keyword.get(:workflow, "WORKFLOW.md") |> Path.expand()

    with {:ok, env_file_path, env_status} <- load_env(opts, workflow_path, deps),
         true <- deps.file_regular?.(workflow_path) || {:error, "workflow file not found: #{workflow_path}"},
         :ok <- deps.set_workflow_file_path.(workflow_path),
         :ok <- deps.validate_config.() do
      settings = deps.settings.()

      {:ok,
       %{
         workflow_path: workflow_path,
         env_file_path: env_file_path,
         env_file_status: env_status,
         settings: settings,
         port: profile_port(opts, settings)
       }}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, format_reason(reason)}
      false -> {:error, "workflow file not found: #{workflow_path}"}
    end
  end

  @spec doctor(keyword(), deps()) :: {:ok, report()} | {:error, report()}
  def doctor(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    {smoke_status, smoke_checks} = smoke_results(opts, deps)

    case prepare(opts, deps) do
      {:ok, context} ->
        {visible_projects, project_errors} = visible_projects(deps)
        configured_slugs = configured_project_slugs(context.settings.tracker)
        project_matches = matching_projects(visible_projects, configured_slugs)
        {linear_context, linear_errors} = linear_context(context.settings, deps)
        {ticket_preview, ticket_errors} = ticket_preview_from_context(context, deps)

        report = %{
          context: context,
          smoke_checks: smoke_checks,
          linear_context: linear_context,
          visible_projects: visible_projects,
          configured_project_slugs: configured_slugs,
          project_matches: project_matches,
          ticket_preview: ticket_preview,
          dashboard: dashboard_context(context.port, deps),
          errors: project_errors ++ linear_errors ++ ticket_errors
        }

        if smoke_status == :ok and report.errors == [], do: {:ok, report}, else: {:error, report}

      {:error, reason} ->
        report = %{
          context: nil,
          smoke_checks: smoke_checks,
          linear_context: nil,
          visible_projects: [],
          configured_project_slugs: [],
          project_matches: [],
          ticket_preview: [],
          dashboard: nil,
          errors: [reason]
        }

        {:error, report}
    end
  end

  @spec ticket_preview(keyword(), deps()) :: {:ok, [ticket_preview()]} | {:error, String.t()}
  def ticket_preview(opts, deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    with {:ok, context} <- prepare(opts, deps) do
      case ticket_preview_from_context(context, deps) do
        {preview, []} -> {:ok, preview}
        {_preview, [error | _rest]} -> {:error, error}
      end
    end
  end

  @spec format_doctor(report()) :: String.t()
  def format_doctor(report) when is_map(report) do
    [
      format_profile_section(report.context),
      format_smoke_section(report.smoke_checks),
      format_linear_section(report),
      format_ticket_preview_section(report.ticket_preview),
      format_dashboard_section(report.dashboard),
      format_error_section(report.errors)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec format_ticket_preview([ticket_preview()]) :: String.t()
  def format_ticket_preview([]), do: "No active-state issues are visible for this profile."

  def format_ticket_preview(previews) when is_list(previews) do
    Enum.map_join(previews, "\n", &format_ticket_preview_line/1)
  end

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      validate_config: &Config.validate!/0,
      settings: &Config.settings!/0,
      smoke_check: fn opts -> SmokeCheck.run(opts) end,
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      list_projects: &Tracker.list_projects/0,
      fetch_issues_by_states: &Tracker.fetch_issues_by_states/1,
      linear_graphql: &Client.graphql/2,
      dashboard_running?: &RunnerProbe.dashboard_running?/1
    }
  end

  defp load_env(opts, workflow_path, deps) do
    case explicit_env_file(opts) do
      {:ok, nil} -> load_default_env(workflow_path, deps)
      {:ok, env_file} -> load_explicit_env(env_file, deps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_default_env(workflow_path, deps) do
    env_file = workflow_path |> Path.dirname() |> Path.join(".env")

    case deps.load_env_file_if_present.(env_file) do
      :ok ->
        status = if deps.file_regular?.(env_file), do: :loaded, else: :not_found
        {:ok, env_file, status}

      {:error, reason} ->
        {:error, "failed to load #{env_file}: #{format_reason(reason)}"}
    end
  end

  defp load_explicit_env(env_file, deps) do
    path = Path.expand(env_file)

    case deps.load_env_file.(path) do
      :ok -> {:ok, path, :loaded}
      {:error, reason} -> {:error, "failed to load #{path}: #{format_reason(reason)}"}
    end
  end

  defp explicit_env_file(opts) do
    case Keyword.get(opts, :env_file) do
      env_file when is_binary(env_file) and env_file != "" ->
        {:ok, env_file}

      env_file when is_binary(env_file) ->
        {:error, "env file must not be blank"}

      _ ->
        profile_env_file(Keyword.get(opts, :profile))
    end
  end

  defp profile_env_file(nil), do: {:ok, nil}

  defp profile_env_file(profile) when is_binary(profile) do
    trimmed = String.trim(profile)

    cond do
      trimmed == "" -> {:error, "profile must not be blank"}
      Regex.match?(@profile_pattern, trimmed) -> {:ok, ".env.#{trimmed}"}
      true -> {:error, "profile may contain only letters, numbers, underscore, dot, and dash"}
    end
  end

  defp profile_env_file(_profile), do: {:ok, nil}

  defp profile_port(opts, settings) do
    case Keyword.get(opts, :port) || settings_server_port(settings) || Config.server_port() do
      port when is_integer(port) and port >= 0 -> port
      _ -> 4000
    end
  end

  defp settings_server_port(%{server: %{port: port}}), do: port
  defp settings_server_port(_settings), do: nil

  defp smoke_results(opts, deps) do
    case deps.smoke_check.(opts) do
      {:ok, results} -> {:ok, results}
      {:error, results} -> {:error, results}
    end
  rescue
    error ->
      {:error, [%{status: :error, check: "doctor smoke check", message: Exception.message(error)}]}
  end

  defp visible_projects(deps) do
    with :ok <- ensure_req_started(deps),
         {:ok, projects} <- deps.list_projects.() do
      {projects, []}
    else
      {:error, reason} -> {[], ["project discovery failed: #{format_reason(reason)}"]}
    end
  end

  defp ensure_req_started(deps) do
    case deps.ensure_req_started.() do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp linear_context(%{tracker: %{kind: "linear"}}, deps) do
    with :ok <- ensure_req_started(deps),
         {:ok, %{"data" => data}} <- deps.linear_graphql.(@linear_context_query, %{}) do
      organization = Map.get(data, "organization") || %{}
      teams = get_in(data, ["teams", "nodes"]) || []
      {%{organization: organization, teams: teams}, []}
    else
      {:ok, _body} -> {nil, ["Linear context query returned an unexpected payload"]}
      {:error, reason} -> {nil, ["Linear context query failed: #{format_reason(reason)}"]}
    end
  end

  defp linear_context(_settings, _deps), do: {nil, []}

  defp ticket_preview_from_context(%{settings: settings}, deps) do
    with :ok <- ensure_req_started(deps),
         {:ok, assignee_match} <- assignee_match(settings, deps),
         {:ok, issues} <- deps.fetch_issues_by_states.(settings.tracker.active_states || []) do
      previews =
        issues
        |> Enum.map(&preview_issue(&1, settings, assignee_match))
        |> Enum.sort_by(&ticket_sort_key/1)

      {previews, []}
    else
      {:error, reason} -> {[], ["ticket preview failed: #{format_reason(reason)}"]}
    end
  end

  defp assignee_match(%{tracker: %{kind: "linear", assignee: assignee}}, deps) when is_binary(assignee) do
    case String.trim(assignee) do
      "" ->
        {:ok, nil}

      "me" ->
        case deps.linear_graphql.(@viewer_query, %{}) do
          {:ok, %{"data" => %{"viewer" => %{"id" => id}}}} when is_binary(id) and id != "" -> {:ok, id}
          {:ok, _body} -> {:error, :missing_linear_viewer_identity}
          {:error, reason} -> {:error, reason}
        end

      id ->
        {:ok, id}
    end
  end

  defp assignee_match(_settings, _deps), do: {:ok, nil}

  defp preview_issue(%Issue{} = issue, settings, assignee_match) do
    reasons =
      []
      |> maybe_add_reason(missing_required_fields?(issue), "missing required issue fields")
      |> maybe_add_reason(not active_state?(issue.state, settings), "state is not active for this runner")
      |> maybe_add_reason(terminal_state?(issue.state, settings), "state is terminal")
      |> maybe_add_reason(not assigned_to_configured_worker?(issue, assignee_match), "assignee does not match runner filter")
      |> maybe_add_reason(has_label?(issue, settings.dispatch.paused_label), "has #{settings.dispatch.paused_label}")
      |> maybe_add_reason(ready_label_missing?(issue, settings), "missing #{settings.dispatch.ready_label}")
      |> maybe_add_reason(blocked_by_non_terminal?(issue, settings), blocked_reason(issue, settings))
      |> Enum.reverse()

    %{
      status: if(reasons == [], do: :ready, else: :skipped),
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      project: issue.project,
      url: issue.url,
      labels: issue.labels,
      reasons: reasons
    }
  end

  defp missing_required_fields?(%Issue{id: id, identifier: identifier, title: title, state: state}) do
    not (non_blank?(id) and non_blank?(identifier) and non_blank?(title) and non_blank?(state))
  end

  defp active_state?(state_name, settings), do: normalized_member?(state_name, settings.tracker.active_states)
  defp terminal_state?(state_name, settings), do: normalized_member?(state_name, settings.tracker.terminal_states)

  defp normalized_member?(value, values) when is_list(values) do
    normalized = normalize(value)
    normalized != "" and Enum.any?(values, &(normalize(&1) == normalized))
  end

  defp normalized_member?(_value, _values), do: false

  defp assigned_to_configured_worker?(_issue, nil), do: true
  defp assigned_to_configured_worker?(%Issue{assignee_id: assignee_id}, assignee_id) when is_binary(assignee_id), do: true
  defp assigned_to_configured_worker?(_issue, _assignee_match), do: false

  defp ready_label_missing?(issue, settings) do
    settings.dispatch.require_ready_label and not has_label?(issue, settings.dispatch.ready_label)
  end

  defp has_label?(%Issue{labels: labels}, wanted_label) when is_list(labels) and is_binary(wanted_label) do
    wanted = normalize(wanted_label)
    wanted != "" and Enum.any?(labels, &(normalize(&1) == wanted))
  end

  defp has_label?(_issue, _wanted_label), do: false

  defp blocked_by_non_terminal?(%Issue{state: state, blocked_by: blockers}, settings) when is_list(blockers) do
    normalize(state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} -> not terminal_state?(blocker_state, settings)
        _ -> true
      end)
  end

  defp blocked_by_non_terminal?(_issue, _settings), do: false

  defp blocked_reason(%Issue{blocked_by: blockers}, settings) do
    blockers =
      blockers
      |> Enum.reject(fn
        %{state: blocker_state} -> terminal_state?(blocker_state, settings)
        _ -> false
      end)
      |> Enum.map_join(", ", fn blocker -> Map.get(blocker, :identifier) || Map.get(blocker, :id) || "unknown blocker" end)

    "blocked by non-terminal issue(s): #{blockers}"
  end

  defp maybe_add_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_reason(reasons, _condition, _reason), do: reasons

  defp ticket_sort_key(%{status: status, state: state, identifier: identifier}) do
    {if(status == :ready, do: 0, else: 1), normalize(state), identifier || ""}
  end

  defp dashboard_context(port, deps) when is_integer(port) and port > 0 do
    %{port: port, url: RunnerProbe.dashboard_url(port), running?: deps.dashboard_running?.(port)}
  end

  defp dashboard_context(_port, _deps), do: nil

  defp configured_project_slugs(tracker) do
    case Map.get(tracker, :project_slugs, []) do
      slugs when is_list(slugs) and slugs != [] -> slugs
      _ -> [Map.get(tracker, :project_slug)]
    end
    |> Enum.map(&normalize_project_slug/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_project_slug(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      slug -> slug
    end
  end

  defp normalize_project_slug(_value), do: nil

  defp matching_projects(projects, configured_slugs) do
    configured = MapSet.new(configured_slugs)
    Enum.filter(projects, fn project -> MapSet.member?(configured, project.slug) end)
  end

  defp format_profile_section(nil), do: "Profile\n  [error] runner config unavailable"

  defp format_profile_section(context) do
    [
      "Profile",
      "  workflow: #{context.workflow_path}",
      "  env file: #{format_env_file(context)}",
      "  dashboard port: #{context.port}"
    ]
    |> Enum.join("\n")
  end

  defp format_env_file(%{env_file_path: nil}), do: "not configured"
  defp format_env_file(%{env_file_path: path, env_file_status: :loaded}), do: "#{path} (loaded)"
  defp format_env_file(%{env_file_path: path, env_file_status: :not_found}), do: "#{path} (not present, optional)"
  defp format_env_file(%{env_file_path: path}), do: to_string(path)

  defp format_smoke_section(results) do
    lines = Enum.map(results, fn result -> "  [#{result.status}] #{result.check}: #{result.message}" end)
    Enum.join(["Smoke Checks" | lines], "\n")
  end

  defp format_linear_section(%{linear_context: context, visible_projects: projects, configured_project_slugs: slugs, project_matches: matches}) do
    organization_line =
      case context do
        %{organization: %{"name" => name, "urlKey" => url_key}} -> "  organization: #{name} (#{url_key})"
        _ -> "  organization: unavailable"
      end

    [
      "Linear",
      organization_line,
      "  configured project slug(s): #{format_list(slugs)}",
      "  matching project(s): #{format_projects(matches)}",
      "  visible project(s): #{format_projects(projects)}"
    ]
    |> Enum.join("\n")
  end

  defp format_ticket_preview_section(previews), do: "Ticket Preview\n" <> indent(format_ticket_preview(previews))

  defp format_dashboard_section(nil), do: ""

  defp format_dashboard_section(%{url: url, running?: true}), do: "Dashboard\n  [ok] running at #{url}"
  defp format_dashboard_section(%{url: url}), do: "Dashboard\n  [skip] not currently running at #{url}"

  defp format_error_section([]), do: ""

  defp format_error_section(errors) do
    errors
    |> Enum.map(&"  [error] #{&1}")
    |> then(&Enum.join(["Errors" | &1], "\n"))
  end

  defp format_ticket_preview_line(%{status: :ready} = preview) do
    "  [ready] #{ticket_label(preview)}: #{preview.state} + dispatch gates pass"
  end

  defp format_ticket_preview_line(%{reasons: reasons} = preview) do
    "  [skipped] #{ticket_label(preview)}: #{Enum.join(reasons, "; ")}"
  end

  defp ticket_label(%{identifier: identifier, title: title}) do
    [identifier || "unknown", title]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_projects([]), do: "none"

  defp format_projects(projects) do
    Enum.map_join(projects, ", ", fn project ->
      "#{project.name || "unnamed"} slug=#{project.slug || "n/a"}"
    end)
  end

  defp format_list([]), do: "none"
  defp format_list(values), do: Enum.join(values, ", ")

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &"  #{&1}")
  end

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  defp format_reason(reason) when is_binary(reason), do: SecretRedactor.redact_string(reason)
  defp format_reason(reason), do: SecretRedactor.inspect_redacted(reason)
end
