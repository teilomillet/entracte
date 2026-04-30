defmodule SymphonyElixir.BootstrapTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Bootstrap, EnvFile}
  alias SymphonyElixir.Tracker.Project

  test "selects the only visible project, writes env, installs labels states templates and views, and runs checks" do
    parent = self()
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    previous_workspace_root = System.get_env("SYMPHONY_WORKSPACE_ROOT")
    previous_runtime_preset = System.get_env("ENTRACTE_RUNTIME_PRESET")
    previous_codex_bin = System.get_env("CODEX_BIN")
    previous_sari_bin = System.get_env("SARI_BIN")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("SOURCE_REPO_URL", previous_source_repo_url)
      restore_env("SYMPHONY_WORKSPACE_ROOT", previous_workspace_root)
      restore_env("ENTRACTE_RUNTIME_PRESET", previous_runtime_preset)
      restore_env("CODEX_BIN", previous_codex_bin)
      restore_env("SARI_BIN", previous_sari_bin)
    end)

    System.put_env("LINEAR_API_KEY", "lin_api_key")
    System.delete_env("SOURCE_REPO_URL")
    System.delete_env("SYMPHONY_WORKSPACE_ROOT")
    System.delete_env("ENTRACTE_RUNTIME_PRESET")
    System.delete_env("CODEX_BIN")
    System.delete_env("SARI_BIN")

    root = tmp_dir()
    workflow_path = Path.join(root, "WORKFLOW.md")
    env_path = Path.join(root, ".env")

    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\n")

    File.write!(Path.join(root, ".env.example"), """
    LINEAR_API_KEY=
    LINEAR_PROJECT_SLUG=
    SOURCE_REPO_URL=
    """)

    assert {:ok, result} =
             Bootstrap.run(
               [workflow: workflow_path],
               deps(parent,
                 projects: [project("Only Project", "only-project")],
                 git_remote_url: fn -> {:ok, "git@github.com:acme/only.git"} end
               )
             )

    assert result.env_file == env_path
    assert result.project_slugs == ["only-project"]
    assert result.runtime_preset == "codex/app_server"
    assert result.smoke_check == {:ok, []}

    assert File.read!(env_path) =~ "LINEAR_API_KEY=lin_api_key"
    assert File.read!(env_path) =~ "LINEAR_PROJECT_SLUG=only-project"
    assert File.read!(env_path) =~ "LINEAR_PROJECT_SLUGS=\"\""
    assert File.read!(env_path) =~ "SOURCE_REPO_URL=git@github.com:acme/only.git"
    assert File.read!(env_path) =~ "SYMPHONY_WORKSPACE_ROOT=~/code/symphony-workspaces"
    assert File.read!(env_path) =~ "ENTRACTE_RUNTIME_PRESET=codex/app_server"
    assert File.read!(env_path) =~ "CODEX_BIN=codex"

    assert_received {:install_labels, [workflow: ^workflow_path, env_file: ^env_path]}
    assert_received {:install_workflow_states, [workflow: ^workflow_path, env_file: ^env_path]}
    assert_received {:install_templates, [workflow: ^workflow_path, env_file: ^env_path]}
    assert_received {:install_views, [workflow: ^workflow_path, env_file: ^env_path]}
    assert_received {:smoke_check, [workflow: ^workflow_path, env_file: ^env_path]}
  end

  test "returns project choices instead of guessing when several projects are visible" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_api_key) end)
    System.put_env("LINEAR_API_KEY", "lin_api_key")

    root = tmp_dir()
    workflow_path = Path.join(root, "WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\n")

    assert {:error, {:multiple_tracker_projects, projects}} =
             Bootstrap.run(
               [workflow: workflow_path],
               deps(self(), projects: [project("A", "a-slug"), project("B", "b-slug")])
             )

    assert Enum.map(projects, & &1.slug) == ["a-slug", "b-slug"]
  end

  test "writes a canonical Sari runtime preset when requested" do
    with_env(
      %{
        "LINEAR_API_KEY" => "lin_api_key",
        "ENTRACTE_RUNTIME_PRESET" => nil,
        "SARI_BIN" => nil,
        "SARI_OPENCODE_BASE_URL" => nil
      },
      fn ->
        root = tmp_dir()
        workflow_path = Path.join(root, "WORKFLOW.md")
        env_path = Path.join(root, ".env")

        File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\n")

        assert {:ok, result} =
                 Bootstrap.run(
                   [
                     workflow: workflow_path,
                     runtime: "claude_code",
                     sari_bin: "/opt/sari/scripts/sari_app_server",
                     skip_check: true
                   ],
                   deps(self(),
                     projects: [project("Only Project", "only-project")],
                     git_remote_url: fn -> {:ok, "git@github.com:acme/only.git"} end
                   )
                 )

        assert result.runtime_preset == "sari/claude_code"
        assert result.smoke_check == :skipped

        env_content = File.read!(env_path)
        assert env_content =~ "ENTRACTE_RUNTIME_PRESET=sari/claude_code"
        assert env_content =~ "SARI_BIN=/opt/sari/scripts/sari_app_server"
        refute env_content =~ "CODEX_BIN="
      end
    )
  end

  test "requires SARI_BIN when bootstrapping a Sari runtime" do
    with_env(
      %{
        "LINEAR_API_KEY" => "lin_api_key",
        "ENTRACTE_RUNTIME_PRESET" => nil,
        "SARI_BIN" => nil
      },
      fn ->
        root = tmp_dir()
        workflow_path = Path.join(root, "WORKFLOW.md")
        File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\n")

        assert {:error, {:missing_sari_bin, "sari/claude_code"}} =
                 Bootstrap.run(
                   [workflow: workflow_path, runtime: "sari/claude_code", skip_check: true],
                   deps(self(), projects: [project("Only Project", "only-project")])
                 )
      end
    )
  end

  test "writes the OpenCode base URL for the Sari OpenCode preset" do
    with_env(
      %{
        "LINEAR_API_KEY" => "lin_api_key",
        "ENTRACTE_RUNTIME_PRESET" => nil,
        "SARI_BIN" => nil,
        "SARI_OPENCODE_BASE_URL" => nil
      },
      fn ->
        root = tmp_dir()
        workflow_path = Path.join(root, "WORKFLOW.md")
        env_path = Path.join(root, ".env")
        File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\n")

        assert {:ok, result} =
                 Bootstrap.run(
                   [
                     workflow: workflow_path,
                     runtime: "opencode",
                     sari_bin: "/opt/sari/scripts/sari_app_server",
                     skip_check: true
                   ],
                   deps(self(), projects: [project("Only Project", "only-project")])
                 )

        assert result.runtime_preset == "sari/opencode_lmstudio"

        env_content = File.read!(env_path)
        assert env_content =~ "ENTRACTE_RUNTIME_PRESET=sari/opencode_lmstudio"
        assert env_content =~ "SARI_OPENCODE_BASE_URL=http://127.0.0.1:41888"
      end
    )
  end

  defp deps(parent, opts) do
    projects = Keyword.fetch!(opts, :projects)
    git_remote_url = Keyword.get(opts, :git_remote_url, fn -> {:error, :missing_remote} end)

    %{
      file_regular?: &File.regular?/1,
      read_file: &File.read/1,
      write_file: &File.write/2,
      copy_file: &File.cp/2,
      mkdir_p: &File.mkdir_p/1,
      load_env_file: &EnvFile.load/1,
      load_env_file_if_present: &EnvFile.load_if_present/1,
      load_env_file_preserving_existing: fn path -> EnvFile.load_if_present(path, override: false) end,
      set_workflow_file_path: fn _path -> :ok end,
      ensure_req_started: fn -> {:ok, [:req]} end,
      list_projects: fn -> {:ok, Enum.map(projects, &normalize_project/1)} end,
      tracker_env_entries: &linear_tracker_env_entries/2,
      get_env: &System.get_env/1,
      git_remote_url: git_remote_url,
      install_labels: fn opts ->
        send(parent, {:install_labels, opts})
        {:ok, []}
      end,
      install_workflow_states: fn opts ->
        send(parent, {:install_workflow_states, opts})
        {:ok, []}
      end,
      install_templates: fn opts ->
        send(parent, {:install_templates, opts})
        {:ok, []}
      end,
      install_views: fn opts ->
        send(parent, {:install_views, opts})
        {:ok, []}
      end,
      smoke_check: fn opts ->
        send(parent, {:smoke_check, opts})
        {:ok, []}
      end
    }
  end

  defp project(name, slug) do
    %{
      "id" => "project-#{slug}",
      "name" => name,
      "slugId" => slug,
      "url" => "https://linear.app/acme/project/#{slug}",
      "teams" => %{"nodes" => [%{"id" => "team-1", "key" => "ENG", "name" => "Engineering"}]}
    }
  end

  defp normalize_project(%{"slugId" => slug} = project) do
    team = project |> get_in(["teams", "nodes"]) |> List.first()

    %Project{
      id: project["id"],
      name: project["name"],
      slug: slug,
      url: project["url"],
      team_id: team["id"],
      team_key: team["key"],
      team_name: team["name"],
      metadata: %{provider: :linear, raw: project, team: team}
    }
  end

  defp linear_tracker_env_entries([project], opts) do
    {:ok,
     %{
       "LINEAR_API_KEY" => System.get_env("LINEAR_API_KEY"),
       "LINEAR_PROJECT_SLUG" => project.slug,
       "LINEAR_PROJECT_SLUGS" => "",
       "LINEAR_ASSIGNEE" => Keyword.get(opts, :assignee, "me")
     }}
  end

  defp linear_tracker_env_entries(projects, opts) do
    {:ok,
     %{
       "LINEAR_API_KEY" => System.get_env("LINEAR_API_KEY"),
       "LINEAR_PROJECT_SLUG" => "",
       "LINEAR_PROJECT_SLUGS" => Enum.map_join(projects, ",", & &1.slug),
       "LINEAR_ASSIGNEE" => Keyword.get(opts, :assignee, "me")
     }}
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "symphony-bootstrap-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp with_env(assignments, fun) when is_function(fun, 0) do
    previous = Map.new(assignments, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(assignments, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end
  end
end
