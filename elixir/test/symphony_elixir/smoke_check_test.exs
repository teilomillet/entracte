defmodule SymphonyElixir.SmokeCheckTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SmokeCheck

  test "passes when local config and read-only external checks succeed" do
    assert {:ok, results} = SmokeCheck.run([workflow: "WORKFLOW.md"], deps())

    assert_result(results, :ok, "env file")
    assert_result(results, :ok, "workflow config")
    assert_result(results, :ok, "workspace root")
    assert_result(results, :ok, "Linear auth")
    assert_result(results, :ok, "Linear project")
    assert_result(results, :ok, "Linear issue poll")
    assert_result(results, :ok, "source repo")
    assert_result(results, :ok, "Codex binary")
  end

  test "fails early when an explicit env file cannot be loaded" do
    failing_deps = deps(load_env_file: fn _path -> {:error, :enoent} end)

    assert {:error, [%{status: :error, check: "env file", message: message}]} =
             SmokeCheck.run([env_file: "missing.env"], failing_deps)

    assert message =~ "failed to load"
    assert message =~ ":enoent"
  end

  test "loads profile env files when profile is provided" do
    parent = self()

    profile_deps =
      deps(
        load_env_file: fn path ->
          send(parent, {:load_env_file, path})
          :ok
        end,
        load_env_file_if_present: fn path ->
          send(parent, {:load_env_file_if_present, path})
          :ok
        end
      )

    assert {:ok, results} = SmokeCheck.run([profile: "client-a"], profile_deps)

    assert_result(results, :ok, "env file", ".env.client-a")
    assert_received {:load_env_file, env_file}
    assert Path.basename(env_file) == ".env.client-a"
    refute_received {:load_env_file_if_present, _path}
  end

  test "reports bad Linear auth and URL-shaped project slug without running dependent Linear checks" do
    bad_settings = settings(project_slug: "https://linear.app/acme/")

    failing_deps =
      deps(
        settings: fn -> bad_settings end,
        mkdir_p: fn _path -> {:error, :eacces} end,
        linear_graphql: fn _query, _variables -> {:error, {:linear_api_status, 401}} end,
        get_env: fn
          "SOURCE_REPO_URL" -> ""
          "CODEX_BIN" -> "missing-codex"
          _key -> nil
        end,
        codex_version: fn _bin -> {:error, "not found on PATH: missing-codex"} end
      )

    assert {:error, results} = SmokeCheck.run([], failing_deps)

    assert_result(results, :error, "workspace root")
    assert_result(results, :error, "Linear auth", "HTTP 401")
    assert_result(results, :error, "Linear project slug", "not a full Linear URL")
    assert_result(results, :skip, "Linear project")
    assert_result(results, :skip, "Linear issue poll")
    assert_result(results, :error, "source repo", "blank")
    assert_result(results, :error, "Codex binary", "missing-codex")
  end

  test "fails when the configured project slug is well-shaped but not found" do
    project_missing_deps =
      deps(
        linear_graphql: fn query, _variables ->
          cond do
            String.contains?(query, "viewer") ->
              {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}

            String.contains?(query, "projects") ->
              {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}
          end
        end,
        fetch_candidate_issues: fn -> flunk("issue poll should wait for project lookup") end
      )

    assert {:error, results} = SmokeCheck.run([], project_missing_deps)

    assert_result(results, :ok, "Linear auth")
    assert_result(results, :ok, "Linear project slug")
    assert_result(results, :error, "Linear project", "no project matched")
    assert_result(results, :skip, "Linear issue poll")
  end

  test "reports candidate issue polling failures after project lookup succeeds" do
    poll_failing_deps = deps(fetch_candidate_issues: fn -> {:error, :boom} end)

    assert {:error, results} = SmokeCheck.run([], poll_failing_deps)

    assert_result(results, :ok, "Linear project")
    assert_result(results, :error, "Linear issue poll", ":boom")
  end

  test "checks Sari binary instead of Codex when the runtime preset selects Sari" do
    sari_deps =
      deps(
        settings: fn -> settings(runtime_preset: "sari/claude_code") end,
        get_env: fn
          "SOURCE_REPO_URL" -> "https://github.com/acme/project.git"
          "SARI_BIN" -> "/opt/sari/scripts/sari_app_server"
          _key -> nil
        end,
        file_regular?: fn
          "/opt/sari/scripts/sari_app_server" -> true
          _path -> true
        end
      )

    assert {:ok, results} = SmokeCheck.run([], sari_deps)

    assert_result(results, :ok, "Sari binary", "/opt/sari/scripts/sari_app_server")
    refute Enum.any?(results, &(&1.check == "Codex binary"))
  end

  test "reports a missing Sari binary for Sari runtime presets" do
    sari_deps =
      deps(
        settings: fn -> settings(runtime_preset: "sari/claude_code") end,
        get_env: fn
          "SOURCE_REPO_URL" -> "https://github.com/acme/project.git"
          _key -> nil
        end
      )

    assert {:error, results} = SmokeCheck.run([], sari_deps)

    assert_result(results, :error, "Sari binary", "SARI_BIN is missing")
    refute Enum.any?(results, &(&1.check == "Codex binary"))
  end

  test "reports missing workflow files after the optional env check" do
    missing_workflow_deps =
      deps(file_regular?: fn path -> Path.basename(path) == ".env" end)

    assert {:error, results} = SmokeCheck.run([workflow: "missing/WORKFLOW.md"], missing_workflow_deps)

    assert_result(results, :ok, "env file")
    assert_result(results, :error, "workflow config", "not found")
  end

  defp deps(overrides \\ []) do
    base = %{
      file_regular?: fn _path -> true end,
      load_env_file: fn _path -> :ok end,
      load_env_file_if_present: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      validate_config: fn -> :ok end,
      settings: fn -> settings() end,
      mkdir_p: fn _path -> :ok end,
      ensure_req_started: fn -> {:ok, [:req]} end,
      linear_graphql: &linear_graphql/2,
      fetch_candidate_issues: fn -> [:candidate] |> then(&{:ok, &1}) end,
      get_env: fn
        "SOURCE_REPO_URL" -> "https://github.com/acme/project.git"
        "CODEX_BIN" -> "codex"
        _key -> nil
      end,
      find_executable: fn
        "sari_app_server" -> "/usr/local/bin/sari_app_server"
        _bin -> nil
      end,
      git_ls_remote: fn _url -> :ok end,
      codex_version: fn "codex" -> {:ok, "codex-cli 0.125.0"} end
    }

    Map.merge(base, Map.new(overrides))
  end

  defp settings(opts \\ []) do
    %{
      tracker: %{
        project_slug: Keyword.get(opts, :project_slug, "project-slug")
      },
      workspace: %{
        root: Keyword.get(opts, :workspace_root, Path.join(System.tmp_dir!(), "symphony-check"))
      },
      runtime: %{
        preset: Keyword.get(opts, :runtime_preset)
      }
    }
  end

  defp linear_graphql(query, _variables) do
    cond do
      String.contains?(query, "viewer") ->
        {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}

      String.contains?(query, "projects") ->
        {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"name" => "Project"}]}}}}
    end
  end

  defp assert_result(results, status, check) do
    assert Enum.any?(results, &(&1.status == status and &1.check == check))
  end

  defp assert_result(results, status, check, message_fragment) do
    assert Enum.any?(results, fn result ->
             result.status == status and result.check == check and String.contains?(result.message, message_fragment)
           end)
  end
end
