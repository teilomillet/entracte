defmodule SymphonyElixir.Bootstrap do
  @moduledoc """
  Bootstraps local runner configuration from tracker API access.
  """

  alias SymphonyElixir.{
    EnvFile,
    RuntimePreset,
    SmokeCheck,
    Tracker,
    TrackerLabelInstaller,
    TrackerTemplateInstaller,
    TrackerViewInstaller,
    TrackerWorkflowStateInstaller,
    Workflow
  }

  alias SymphonyElixir.Tracker.{
    LabelInstallation,
    Project,
    TemplateInstallation,
    ViewInstallation,
    WorkflowStateInstallation
  }

  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/
  @key_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @type result :: %{
          required(:env_file) => Path.t(),
          required(:project_slugs) => [String.t()],
          required(:runtime_preset) => String.t(),
          required(:projects) => [Project.t()],
          required(:label_results) => [LabelInstallation.t()],
          required(:workflow_state_results) => [WorkflowStateInstallation.t()],
          required(:template_results) => [TemplateInstallation.t()],
          required(:view_results) => [ViewInstallation.t()],
          required(:smoke_check) => SmokeCheck.check_result() | :skipped
        }
  @type tracker_env_entries_fun :: ([Project.t()], keyword() ->
                                      {:ok, %{String.t() => String.t()}} | {:error, term()})

  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:read_file) => (String.t() -> {:ok, String.t()} | {:error, term()}),
          required(:write_file) => (String.t(), String.t() -> :ok | {:error, term()}),
          required(:copy_file) => (String.t(), String.t() -> :ok | {:error, term()}),
          required(:mkdir_p) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_preserving_existing) => (String.t() -> :ok | {:error, term()}),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:list_projects) => (-> {:ok, [Project.t()]} | {:error, term()}),
          required(:tracker_env_entries) => tracker_env_entries_fun(),
          required(:get_env) => (String.t() -> String.t() | nil),
          required(:git_remote_url) => (-> {:ok, String.t()} | {:error, term()}),
          required(:install_labels) => (keyword() -> {:ok, [LabelInstallation.t()]} | {:error, term()}),
          required(:install_workflow_states) => (keyword() ->
                                                   {:ok, [WorkflowStateInstallation.t()]} | {:error, term()}),
          required(:install_templates) => (keyword() -> {:ok, [TemplateInstallation.t()]} | {:error, term()}),
          required(:install_views) => (keyword() -> {:ok, [ViewInstallation.t()]} | {:error, term()}),
          required(:smoke_check) => (keyword() -> SmokeCheck.check_result())
        }

  @spec run(keyword(), deps()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    workflow_path = opts |> Keyword.get(:workflow, "WORKFLOW.md") |> Path.expand()

    with {:ok, env_path} <- env_file_path(opts, workflow_path),
         :ok <- ensure_env_file(env_path, workflow_path, deps),
         :ok <- deps.load_env_file_preserving_existing.(env_path),
         :ok <- deps.set_workflow_file_path.(workflow_path),
         {:ok, _apps} <- deps.ensure_req_started.(),
         {:ok, projects} <- fetch_projects(deps),
         {:ok, selected_projects} <- select_projects(projects, opts),
         {:ok, runtime_preset} <- write_runner_env(env_path, selected_projects, opts, deps),
         :ok <- deps.load_env_file.(env_path),
         {:ok, label_results} <- maybe_install_labels(opts, env_path, workflow_path, deps),
         {:ok, workflow_state_results} <- maybe_install_workflow_states(opts, env_path, workflow_path, deps),
         {:ok, template_results} <- maybe_install_templates(opts, env_path, workflow_path, deps),
         {:ok, view_results} <- maybe_install_views(opts, env_path, workflow_path, deps),
         smoke_result <- maybe_smoke_check(opts, env_path, workflow_path, deps) do
      {:ok,
       %{
         env_file: env_path,
         project_slugs: Enum.map(selected_projects, & &1.slug),
         runtime_preset: runtime_preset,
         projects: selected_projects,
         label_results: label_results,
         workflow_state_results: workflow_state_results,
         template_results: template_results,
         view_results: view_results,
         smoke_check: smoke_result
       }}
    end
  end

  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      read_file: &File.read/1,
      write_file: &File.write/2,
      copy_file: &File.cp/2,
      mkdir_p: &File.mkdir_p/1,
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      load_env_file_preserving_existing: fn path -> EnvFile.load_if_present(path, override: false) end,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      list_projects: &Tracker.list_projects/0,
      tracker_env_entries: &Tracker.bootstrap_env_entries/2,
      get_env: &System.get_env/1,
      git_remote_url: &git_remote_url/0,
      install_labels: &TrackerLabelInstaller.install/1,
      install_workflow_states: &TrackerWorkflowStateInstaller.install/1,
      install_templates: &TrackerTemplateInstaller.install/1,
      install_views: &TrackerViewInstaller.install/1,
      smoke_check: &SmokeCheck.run/1
    }
  end

  defp env_file_path(opts, workflow_path) do
    cond do
      is_binary(Keyword.get(opts, :env_file)) and Keyword.get(opts, :env_file) != "" ->
        {:ok, opts |> Keyword.fetch!(:env_file) |> Path.expand()}

      is_binary(Keyword.get(opts, :env_file)) ->
        {:error, :blank_env_file}

      is_binary(Keyword.get(opts, :profile)) ->
        profile_env_file(Keyword.fetch!(opts, :profile))

      true ->
        {:ok, workflow_path |> Path.dirname() |> Path.join(".env")}
    end
  end

  defp profile_env_file(profile) do
    trimmed = String.trim(profile)

    if Regex.match?(@profile_pattern, trimmed) do
      {:ok, Path.expand(".env.#{trimmed}")}
    else
      {:error, :invalid_profile}
    end
  end

  defp ensure_env_file(env_path, workflow_path, deps) do
    cond do
      deps.file_regular?.(env_path) ->
        :ok

      deps.file_regular?.(env_example_path(workflow_path)) ->
        with :ok <- deps.mkdir_p.(Path.dirname(env_path)) do
          deps.copy_file.(env_example_path(workflow_path), env_path)
        end

      true ->
        with :ok <- deps.mkdir_p.(Path.dirname(env_path)) do
          deps.write_file.(env_path, "")
        end
    end
  end

  defp env_example_path(workflow_path), do: workflow_path |> Path.dirname() |> Path.join(".env.example")

  defp fetch_projects(deps) do
    deps.list_projects.()
  end

  defp select_projects(projects, opts) do
    cond do
      projects == [] ->
        {:error, :tracker_no_projects}

      is_binary(Keyword.get(opts, :project)) and Keyword.get(opts, :project) != "" ->
        select_project_by_slug(projects, Keyword.fetch!(opts, :project))

      Keyword.get(opts, :all_projects, false) ->
        {:ok, projects}

      length(projects) == 1 ->
        {:ok, projects}

      true ->
        {:error, {:multiple_tracker_projects, projects}}
    end
  end

  defp select_project_by_slug(projects, slug) do
    trimmed_slug = String.trim(slug)

    case Enum.find(projects, &(&1.slug == trimmed_slug)) do
      nil -> {:error, {:tracker_project_not_found, trimmed_slug, projects}}
      project -> {:ok, [project]}
    end
  end

  defp write_runner_env(env_path, selected_projects, opts, deps) do
    with {:ok, tracker_entries} <- deps.tracker_env_entries.(selected_projects, opts),
         {:ok, runtime_preset, runtime_entries} <- runtime_env_entries(opts, deps) do
      entries =
        tracker_entries
        |> maybe_put("SOURCE_REPO_URL", source_repo_url(opts, deps))
        |> maybe_put("SYMPHONY_WORKSPACE_ROOT", workspace_root(opts, env_path))
        |> maybe_put("SYMPHONY_PORT", Keyword.get(opts, :port))
        |> Map.merge(runtime_entries)

      with :ok <- upsert_env_file(env_path, entries, deps) do
        {:ok, runtime_preset}
      end
    end
  end

  defp runtime_env_entries(opts, deps) do
    with {:ok, runtime_preset} <- runtime_preset(opts, deps),
         {:ok, preset} <- RuntimePreset.get(runtime_preset),
         {:ok, entries} <- do_runtime_env_entries(preset, opts, deps) do
      {:ok, runtime_preset, entries}
    end
  end

  defp runtime_preset(opts, deps) do
    opts
    |> Keyword.get(:runtime)
    |> case do
      runtime when is_binary(runtime) ->
        RuntimePreset.normalize(runtime)

      _ ->
        deps.get_env.("ENTRACTE_RUNTIME_PRESET")
        |> normalize_env()
        |> RuntimePreset.normalize()
    end
  end

  defp do_runtime_env_entries(%{id: runtime_preset, kind: :codex}, opts, deps) do
    codex_bin =
      Keyword.get(opts, :codex_bin) ||
        normalize_env(deps.get_env.("CODEX_BIN")) ||
        "codex"

    {:ok,
     %{
       "ENTRACTE_RUNTIME_PRESET" => runtime_preset,
       "CODEX_BIN" => codex_bin
     }}
  end

  defp do_runtime_env_entries(%{id: runtime_preset, kind: :sari}, opts, deps) do
    case sari_bin(opts, deps) do
      nil ->
        {:error, {:missing_sari_bin, runtime_preset}}

      sari_bin ->
        entries =
          %{
            "ENTRACTE_RUNTIME_PRESET" => runtime_preset,
            "SARI_BIN" => sari_bin
          }
          |> maybe_put("SARI_OPENCODE_BASE_URL", opencode_base_url(opts, deps, runtime_preset))

        {:ok, entries}
    end
  end

  defp sari_bin(opts, deps) do
    Keyword.get(opts, :sari_bin) ||
      normalize_env(deps.get_env.("SARI_BIN"))
  end

  defp opencode_base_url(opts, deps, "sari/opencode_lmstudio") do
    Keyword.get(opts, :opencode_base_url) ||
      normalize_env(deps.get_env.("SARI_OPENCODE_BASE_URL")) ||
      "http://127.0.0.1:41888"
  end

  defp opencode_base_url(_opts, _deps, _runtime_preset), do: nil

  defp source_repo_url(opts, deps) do
    case Keyword.get(opts, :source_repo_url) || normalize_env(deps.get_env.("SOURCE_REPO_URL")) do
      value when is_binary(value) ->
        value

      _ ->
        case deps.git_remote_url.() do
          {:ok, remote_url} -> remote_url
          {:error, _reason} -> nil
        end
    end
  end

  defp workspace_root(opts, env_path) do
    Keyword.get(opts, :workspace_root) ||
      System.get_env("SYMPHONY_WORKSPACE_ROOT") ||
      Path.join(["~", "code", "#{env_profile_name(env_path)}-workspaces"])
  end

  defp env_profile_name(env_path) do
    env_path
    |> Path.basename()
    |> String.replace_prefix(".env.", "")
    |> case do
      ".env" -> "symphony"
      "" -> "symphony"
      profile -> profile
    end
  end

  defp maybe_put(entries, _key, nil), do: entries
  defp maybe_put(entries, _key, ""), do: entries
  defp maybe_put(entries, key, value), do: Map.put(entries, key, to_string(value))

  defp upsert_env_file(env_path, entries, deps) do
    with {:ok, content} <- deps.read_file.(env_path),
         :ok <- validate_env_entries(entries),
         updated_content <- upsert_env_content(content, entries) do
      deps.write_file.(env_path, updated_content)
    end
  end

  defp validate_env_entries(entries) when is_map(entries) do
    case Enum.find(Map.keys(entries), &(not Regex.match?(@key_pattern, &1))) do
      nil -> :ok
      key -> {:error, {:invalid_env_key, key}}
    end
  end

  defp upsert_env_content(content, entries) do
    {lines, seen_keys} =
      content
      |> split_env_lines()
      |> Enum.map_reduce(MapSet.new(), &upsert_env_line(&1, &2, entries))

    appended_lines =
      entries
      |> Enum.reject(fn {key, _value} -> MapSet.member?(seen_keys, key) end)
      |> Enum.map(fn {key, value} -> format_env_assignment(key, value) end)

    lines
    |> append_env_lines(appended_lines)
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  defp split_env_lines(""), do: []

  defp split_env_lines(content) do
    content
    |> String.trim_trailing("\n")
    |> String.split(~r/\R/, trim: false)
  end

  defp upsert_env_line(line, seen_keys, entries) do
    case env_line_key(line) do
      key when is_binary(key) ->
        if Map.has_key?(entries, key) do
          {format_env_assignment(key, Map.fetch!(entries, key)), MapSet.put(seen_keys, key)}
        else
          {line, seen_keys}
        end

      _ ->
        {line, seen_keys}
    end
  end

  defp env_line_key(line) do
    case Regex.run(~r/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/, line) do
      [_line, key] -> key
      _no_match -> nil
    end
  end

  defp append_env_lines(lines, []), do: lines
  defp append_env_lines([], appended_lines), do: appended_lines
  defp append_env_lines(lines, appended_lines), do: lines ++ [""] ++ appended_lines

  defp format_env_assignment(key, value), do: "#{key}=#{format_env_value(value)}"

  defp format_env_value(value) do
    value = to_string(value)

    if Regex.match?(~r/^[^\s#"'\\]+$/, value) do
      value
    else
      "\"" <> escape_double_quoted_env_value(value) <> "\""
    end
  end

  defp escape_double_quoted_env_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp ensure_trailing_newline(content), do: String.trim_trailing(content, "\n") <> "\n"

  defp maybe_install_labels(opts, env_path, workflow_path, deps) do
    if Keyword.get(opts, :skip_label_install, false) do
      {:ok, []}
    else
      deps.install_labels.(workflow: workflow_path, env_file: env_path)
    end
  end

  defp maybe_install_templates(opts, env_path, workflow_path, deps) do
    if Keyword.get(opts, :skip_template_install, false) do
      {:ok, []}
    else
      deps.install_templates.(workflow: workflow_path, env_file: env_path)
    end
  end

  defp maybe_install_workflow_states(opts, env_path, workflow_path, deps) do
    if Keyword.get(opts, :skip_state_install, false) do
      {:ok, []}
    else
      deps.install_workflow_states.(workflow: workflow_path, env_file: env_path)
    end
  end

  defp maybe_install_views(opts, env_path, workflow_path, deps) do
    if Keyword.get(opts, :skip_view_install, false) do
      {:ok, []}
    else
      deps.install_views.(workflow: workflow_path, env_file: env_path)
    end
  end

  defp maybe_smoke_check(opts, env_path, workflow_path, deps) do
    if Keyword.get(opts, :skip_check, false) do
      :skipped
    else
      deps.smoke_check.(workflow: workflow_path, env_file: env_path)
    end
  end

  defp git_remote_url do
    case System.cmd("git", ["config", "--get", "remote.origin.url"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> normalize_env()
        |> case do
          nil -> {:error, :missing_git_remote}
          remote_url -> {:ok, remote_url}
        end

      {output, status} ->
        {:error, {:git_remote_failed, status, String.trim(output)}}
    end
  end

  defp normalize_env(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_env(_value), do: nil
end
