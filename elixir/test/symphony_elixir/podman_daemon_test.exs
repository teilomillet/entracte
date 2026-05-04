defmodule SymphonyElixir.PodmanDaemonTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PodmanDaemon

  test "builds a podman run command for a profile daemon" do
    context = context()

    assert {:ok, args, metadata} =
             PodmanDaemon.start_args_for_test(
               context,
               [
                 name: "ANEF Dev",
                 image: "localhost/entracte-test:latest",
                 repo_root: "/repo/entracte",
                 logs_root: "/repo/entracte/elixir/log/anef",
                 mount_host_auth: true
               ],
               deps()
             )

    assert metadata.name == "entracte-anef-dev"
    assert metadata.image == "localhost/entracte-test:latest"
    assert metadata.port == 4100

    assert option_values(args, "--name") == ["entracte-anef-dev"]
    assert option_values(args, "--publish") == ["127.0.0.1:4100:4100"]
    assert option_values(args, "--workdir") == ["/repo/entracte/elixir"]
    assert option_values(args, "--env-file") == ["/repo/entracte/elixir/.env.anef"]

    volumes = option_values(args, "--volume")
    assert "/repo/entracte:/repo/entracte:rw" in volumes
    assert "/work/anef-workspaces:/work/anef-workspaces:rw" in volumes
    assert "/repo/entracte/elixir/log/anef:/repo/entracte/elixir/log/anef:rw" in volumes
    assert "/home/test/.codex:/root/.codex:ro" in volumes
    assert "/home/test/.config/gh:/root/.config/gh:ro" in volumes
    assert "/home/test/.config/glab:/root/.config/glab:ro" in volumes
    assert "/home/test/.ssh:/root/.ssh:ro" in volumes
    assert "/home/test/.gitconfig:/root/.gitconfig:ro" in volumes

    assert Enum.slice(args, -4, 4) == ["localhost/entracte-test:latest", "bash", "-lc", List.last(args)]
    assert List.last(args) =~ "mix symphony.check"
    assert List.last(args) =~ "mix symphony.start"
    assert List.last(args) =~ "--workflow '/repo/entracte/elixir/WORKFLOW.anef.md'"
    assert List.last(args) =~ "--env-file '/repo/entracte/elixir/.env.anef'"
    assert List.last(args) =~ "--logs-root '/repo/entracte/elixir/log/anef'"
    assert List.last(args) =~ "--port '4100'"
  end

  test "mounts workflow and env files when they are outside the repo mount" do
    context =
      context(
        workflow_path: "/profiles/anef/WORKFLOW.md",
        env_file_path: "/profiles/anef/.env",
        workspace_root: "/work/anef-workspaces"
      )

    assert {:ok, args, _metadata} =
             PodmanDaemon.start_args_for_test(
               context,
               [repo_root: "/repo/entracte", logs_root: "/logs/anef"],
               deps()
             )

    volumes = option_values(args, "--volume")
    assert "/profiles/anef/WORKFLOW.md:/profiles/anef/WORKFLOW.md:ro" in volumes
    assert "/profiles/anef/.env:/profiles/anef/.env:ro" in volumes
  end

  test "start refuses to collide with an already reachable dashboard" do
    parent = self()

    deps =
      deps(
        prepare: fn _opts -> {:ok, context()} end,
        dashboard_running?: fn 4100 -> true end,
        cmd: fn command, args, _opts ->
          send(parent, {:unexpected_cmd, command, args})
          {"", 0}
        end
      )

    assert {:error, reason} = PodmanDaemon.start([repo_root: "/repo/entracte"], deps)
    assert reason =~ "dashboard already responds"
    refute_received {:unexpected_cmd, _command, _args}
  end

  test "status only needs the normalized container name" do
    parent = self()

    deps =
      deps(
        prepare: fn _opts -> flunk("status should not load workflow configuration") end,
        cmd: fn "podman", args, _opts ->
          send(parent, {:podman_args, args})
          {"/entracte-anef running\n", 0}
        end
      )

    assert {:ok, %{status: "/entracte-anef running"}} = PodmanDaemon.status([profile: "anef"], deps)
    assert_received {:podman_args, ["inspect", "--format", "{{.Name}} {{.State.Status}}", "entracte-anef"]}
  end

  test "build uses the repository containerfile by default" do
    parent = self()

    deps =
      deps(
        cwd: fn -> "/repo/entracte/elixir" end,
        cmd: fn "podman", args, _opts ->
          send(parent, {:podman_args, args})
          {"build output\n", 0}
        end
      )

    assert {:ok, %{image: "localhost/entracte-runner:latest"}} = PodmanDaemon.build([], deps)

    assert_received {:podman_args,
                     [
                       "build",
                       "--file",
                       "/repo/entracte/containers/entracte-runner.Containerfile",
                       "--tag",
                       "localhost/entracte-runner:latest",
                       "/repo/entracte"
                     ]}
  end

  defp option_values(args, option) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [^option, value] -> [value]
      _pair -> []
    end)
  end

  defp deps(overrides \\ []) do
    base = %{
      find_executable: fn "podman" -> "/usr/bin/podman" end,
      cmd: fn command, args, _opts -> flunk("unexpected command: #{command} #{inspect(args)}") end,
      prepare: fn _opts -> {:ok, context()} end,
      dashboard_running?: fn _port -> false end,
      cwd: fn -> "/repo/entracte/elixir" end,
      get_env: fn
        "HOME" -> "/home/test"
        _name -> nil
      end,
      file_dir?: fn path ->
        path in ["/home/test/.codex", "/home/test/.config/gh", "/home/test/.config/glab", "/home/test/.ssh"]
      end,
      file_regular?: fn path ->
        path in ["/home/test/.gitconfig"]
      end
    }

    Map.merge(base, Map.new(overrides))
  end

  defp context(opts \\ []) do
    workspace_root = Keyword.get(opts, :workspace_root, "/work/anef-workspaces")

    %{
      workflow_path: Keyword.get(opts, :workflow_path, "/repo/entracte/elixir/WORKFLOW.anef.md"),
      env_file_path: Keyword.get(opts, :env_file_path, "/repo/entracte/elixir/.env.anef"),
      env_file_status: :loaded,
      settings: %Schema{
        workspace: %Schema.Workspace{root: workspace_root},
        server: %Schema.Server{port: 4100}
      },
      port: Keyword.get(opts, :port, 4100)
    }
  end
end
