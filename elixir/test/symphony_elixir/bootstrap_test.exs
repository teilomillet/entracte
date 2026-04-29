defmodule SymphonyElixir.BootstrapTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Bootstrap, EnvFile}
  alias SymphonyElixir.Tracker.Project

  test "selects the only visible project, writes env, installs labels templates and views, and runs checks" do
    parent = self()
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_source_repo_url = System.get_env("SOURCE_REPO_URL")
    previous_workspace_root = System.get_env("SYMPHONY_WORKSPACE_ROOT")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("SOURCE_REPO_URL", previous_source_repo_url)
      restore_env("SYMPHONY_WORKSPACE_ROOT", previous_workspace_root)
    end)

    System.put_env("LINEAR_API_KEY", "lin_api_key")
    System.delete_env("SOURCE_REPO_URL")
    System.delete_env("SYMPHONY_WORKSPACE_ROOT")

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
    assert result.smoke_check == {:ok, []}

    assert File.read!(env_path) =~ "LINEAR_API_KEY=lin_api_key"
    assert File.read!(env_path) =~ "LINEAR_PROJECT_SLUG=only-project"
    assert File.read!(env_path) =~ "LINEAR_PROJECT_SLUGS=\"\""
    assert File.read!(env_path) =~ "SOURCE_REPO_URL=git@github.com:acme/only.git"
    assert File.read!(env_path) =~ "SYMPHONY_WORKSPACE_ROOT=~/code/symphony-workspaces"

    assert_received {:install_labels, [workflow: ^workflow_path, env_file: ^env_path]}
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
end
