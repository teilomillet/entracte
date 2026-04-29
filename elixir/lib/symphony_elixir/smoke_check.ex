defmodule SymphonyElixir.SmokeCheck do
  @moduledoc """
  Non-destructive runtime smoke checks for a local Symphony runner.
  """

  alias SymphonyElixir.{Config, EnvFile, Tracker, Workflow}
  alias SymphonyElixir.Linear.Client

  @profile_pattern ~r/^[A-Za-z0-9_.-]+$/

  @viewer_query """
  query SymphonySmokeViewer {
    viewer {
      id
    }
  }
  """

  @project_query """
  query SymphonySmokeProject($slug: String!) {
    projects(filter: {slugId: {eq: $slug}}, first: 1) {
      nodes {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @type status :: :ok | :error | :skip
  @type result :: %{
          required(:status) => status(),
          required(:check) => String.t(),
          required(:message) => String.t()
        }
  @type check_result :: {:ok, [result()]} | {:error, [result()]}
  @type deps :: %{
          required(:file_regular?) => (String.t() -> boolean()),
          required(:load_env_file) => (String.t() -> :ok | {:error, term()}),
          required(:load_env_file_if_present) => (String.t() -> :ok | {:error, term()}),
          required(:set_workflow_file_path) => (String.t() -> :ok | {:error, term()}),
          required(:validate_config) => (-> :ok | {:error, term()}),
          required(:settings) => (-> map()),
          required(:mkdir_p) => (String.t() -> :ok | {:error, term()}),
          required(:ensure_req_started) => (-> {:ok, [atom()]} | {:error, term()}),
          required(:linear_graphql) => (String.t(), map() -> {:ok, map()} | {:error, term()}),
          required(:fetch_candidate_issues) => (-> {:ok, [term()]} | {:error, term()}),
          required(:get_env) => (String.t() -> String.t() | nil),
          required(:git_ls_remote) => (String.t() -> :ok | {:error, term()}),
          required(:codex_version) => (String.t() -> {:ok, String.t()} | {:error, term()})
        }

  @spec run(keyword(), deps()) :: check_result()
  def run(opts \\ [], deps \\ runtime_deps()) when is_list(opts) and is_map(deps) do
    workflow_path = opts |> Keyword.get(:workflow, "WORKFLOW.md") |> Path.expand()
    env_file = Keyword.get(opts, :env_file) || profile_env_selector(Keyword.get(opts, :profile))

    case check_env_file(env_file, workflow_path, deps) do
      {:ok, env_result} ->
        case check_workflow(workflow_path, deps) do
          {:ok, settings, workflow_result} ->
            [
              env_result,
              workflow_result,
              check_workspace(settings, deps)
            ]
            |> Kernel.++(check_linear(settings, deps))
            |> Kernel.++([check_source_repo(deps), check_codex(deps)])
            |> finalize()

          {:error, workflow_result} ->
            {:error, [env_result, workflow_result]}
        end

      {:error, env_result} ->
        {:error, [env_result]}
    end
  end

  defp profile_env_selector(profile) when is_binary(profile), do: {:profile, profile}
  defp profile_env_selector(_profile), do: nil

  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      validate_config: &Config.validate!/0,
      settings: &Config.settings!/0,
      mkdir_p: &File.mkdir_p/1,
      ensure_req_started: fn -> Application.ensure_all_started(:req) end,
      linear_graphql: &Client.graphql/2,
      fetch_candidate_issues: &Tracker.fetch_candidate_issues/0,
      get_env: &System.get_env/1,
      git_ls_remote: &git_ls_remote/1,
      codex_version: &codex_version/1
    }
  end

  defp check_env_file(nil, workflow_path, deps) do
    check_profile_or_default_env_file(nil, workflow_path, deps)
  end

  defp check_env_file(env_file, _workflow_path, deps) when is_binary(env_file) do
    env_path = Path.expand(env_file)

    case deps.load_env_file.(env_path) do
      :ok -> {:ok, ok("env file", "loaded #{env_path}")}
      {:error, reason} -> {:error, fail("env file", "failed to load #{env_path}: #{format_reason(reason)}")}
    end
  end

  defp check_env_file({:profile, profile}, _workflow_path, deps) do
    case profile_env_file(profile) do
      {:ok, env_path} -> load_profile_env_file(env_path, deps)
      {:error, reason} -> {:error, fail("env file", "invalid profile: #{format_reason(reason)}")}
    end
  end

  defp load_profile_env_file(env_path, deps) do
    case deps.load_env_file.(env_path) do
      :ok -> {:ok, ok("env file", "loaded #{env_path}")}
      {:error, reason} -> {:error, fail("env file", "failed to load #{env_path}: #{format_reason(reason)}")}
    end
  end

  defp check_profile_or_default_env_file(_env_file, workflow_path, deps) do
    env_path = workflow_path |> Path.dirname() |> Path.join(".env")

    case deps.load_env_file_if_present.(env_path) do
      :ok ->
        message =
          if deps.file_regular?.(env_path) do
            "loaded #{env_path}"
          else
            "no .env file found next to workflow"
          end

        {:ok, ok("env file", message)}

      {:error, reason} ->
        {:error, fail("env file", "failed to load #{env_path}: #{format_reason(reason)}")}
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

  defp check_workflow(workflow_path, deps) do
    if deps.file_regular?.(workflow_path) do
      with :ok <- deps.set_workflow_file_path.(workflow_path),
           :ok <- deps.validate_config.() do
        {:ok, deps.settings.(), ok("workflow config", "valid #{workflow_path}")}
      else
        {:error, reason} ->
          {:error, fail("workflow config", "invalid #{workflow_path}: #{format_reason(reason)}")}
      end
    else
      {:error, fail("workflow config", "workflow file not found: #{workflow_path}")}
    end
  end

  defp check_workspace(settings, deps) do
    workspace_root = settings.workspace.root |> to_string() |> Path.expand()

    case deps.mkdir_p.(workspace_root) do
      :ok -> ok("workspace root", "ready #{workspace_root}")
      {:error, reason} -> fail("workspace root", "cannot create #{workspace_root}: #{format_reason(reason)}")
    end
  end

  defp check_linear(settings, deps) do
    auth_result = check_linear_auth(deps)
    project_slugs = project_slugs(settings.tracker)
    slug_result = check_project_slug_shape(project_slugs)
    project_result = maybe_check_projects(auth_result, slug_result, project_slugs, deps)
    poll_result = maybe_check_issue_poll(project_result, deps)

    [auth_result, slug_result, project_result, poll_result]
  end

  defp check_linear_auth(deps) do
    with {:ok, _apps} <- deps.ensure_req_started.(),
         {:ok, %{"data" => %{"viewer" => %{"id" => viewer_id}}}} when is_binary(viewer_id) <-
           deps.linear_graphql.(@viewer_query, %{}) do
      ok("Linear auth", "viewer query succeeded")
    else
      {:error, reason} -> fail("Linear auth", format_reason(reason))
      _ -> fail("Linear auth", "viewer query returned an unexpected payload")
    end
  end

  defp check_project_slug_shape(project_slugs) when is_list(project_slugs) do
    cond do
      project_slugs == [] ->
        fail("Linear project slug", "LINEAR_PROJECT_SLUG or LINEAR_PROJECT_SLUGS is missing")

      invalid_slug = Enum.find(project_slugs, &url_shaped_slug?/1) ->
        fail("Linear project slug", "use only the slug after /project/, not a full Linear URL: #{invalid_slug}")

      true ->
        ok("Linear project slug", "#{length(project_slugs)} slug(s) look valid")
    end
  end

  defp url_shaped_slug?(project_slug) when is_binary(project_slug) do
    String.contains?(project_slug, ["/", "http://", "https://"])
  end

  defp maybe_check_projects(%{status: :ok}, %{status: :ok}, project_slugs, deps) do
    project_slugs
    |> Enum.reduce_while({:ok, []}, fn project_slug, {:ok, projects} ->
      case lookup_project(project_slug, deps) do
        {:ok, project} -> {:cont, {:ok, [project | projects]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, projects} ->
        names =
          projects
          |> Enum.reverse()
          |> Enum.map_join(", ", fn project -> project["name"] || project["slugId"] || "unnamed project" end)

        ok("Linear project", "found #{names}")

      {:error, message} ->
        fail("Linear project", message)
    end
  end

  defp maybe_check_projects(_auth_result, _slug_result, _project_slugs, _deps) do
    skip("Linear project", "skipped until Linear auth and project slug are valid")
  end

  defp lookup_project(project_slug, deps) do
    case deps.linear_graphql.(@project_query, %{slug: project_slug}) do
      {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} ->
        {:ok, project}

      {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
        {:error, "no project matched #{project_slug}"}

      {:ok, _body} ->
        {:error, "project lookup returned an unexpected payload"}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  defp project_slugs(tracker) do
    case Map.get(tracker, :project_slugs, []) do
      slugs when is_list(slugs) and slugs != [] ->
        slugs
        |> Enum.map(&normalize_project_slug/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        tracker
        |> Map.get(:project_slug)
        |> normalize_project_slug()
        |> case do
          nil -> []
          slug -> [slug]
        end
    end
  end

  defp normalize_project_slug(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      slug -> slug
    end
  end

  defp normalize_project_slug(_value), do: nil

  defp maybe_check_issue_poll(%{status: :ok}, deps) do
    case deps.fetch_candidate_issues.() do
      {:ok, issues} -> ok("Linear issue poll", "#{length(issues)} candidate issue(s) visible")
      {:error, reason} -> fail("Linear issue poll", format_reason(reason))
    end
  end

  defp maybe_check_issue_poll(_project_result, _deps) do
    skip("Linear issue poll", "skipped until Linear project lookup succeeds")
  end

  defp check_source_repo(deps) do
    case deps.get_env.("SOURCE_REPO_URL") do
      source_repo_url when is_binary(source_repo_url) ->
        check_source_repo_url(String.trim(source_repo_url), deps)

      _ ->
        fail("source repo", "SOURCE_REPO_URL is missing")
    end
  end

  defp check_source_repo_url("", _deps), do: fail("source repo", "SOURCE_REPO_URL is blank")

  defp check_source_repo_url(source_repo_url, deps) do
    case deps.git_ls_remote.(source_repo_url) do
      :ok -> ok("source repo", "git ls-remote succeeded")
      {:error, reason} -> fail("source repo", format_reason(reason))
    end
  end

  defp check_codex(deps) do
    codex_bin =
      case deps.get_env.("CODEX_BIN") do
        value when is_binary(value) and value != "" -> value
        _ -> "codex"
      end

    case deps.codex_version.(codex_bin) do
      {:ok, version} -> ok("Codex binary", String.trim(version))
      {:error, reason} -> fail("Codex binary", format_reason(reason))
    end
  end

  defp git_ls_remote(source_repo_url) do
    case System.cmd("git", ["ls-remote", "--heads", source_repo_url],
           env: [{"GIT_TERMINAL_PROMPT", "0"}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "git ls-remote exited #{status}: #{String.slice(output, 0, 500)}"}
    end
  end

  defp codex_version(codex_bin) do
    case System.find_executable(codex_bin) do
      nil ->
        {:error, "not found on PATH: #{codex_bin}"}

      path ->
        case System.cmd(path, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, "exited #{status}: #{String.slice(output, 0, 500)}"}
        end
    end
  end

  defp finalize(results) do
    if Enum.any?(results, &(&1.status == :error)) do
      {:error, results}
    else
      {:ok, results}
    end
  end

  defp ok(check, message), do: %{status: :ok, check: check, message: message}
  defp fail(check, message), do: %{status: :error, check: check, message: message}
  defp skip(check, message), do: %{status: :skip, check: check, message: message}

  defp format_reason({:linear_api_status, status}), do: "Linear API returned HTTP #{status}"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
