defmodule SymphonyElixir.StartCommandTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.StartCommand

  test "builds default start args and preloads .env next to the workflow" do
    parent = self()

    assert {:ok, args} = StartCommand.cli_args([], deps(parent))

    assert args == [
             StartCommand.ack_flag(),
             "--port",
             "4000",
             "WORKFLOW.md"
           ]

    assert_received {:load_env_if_present, env_path}
    assert Path.basename(env_path) == ".env"
  end

  test "profile loads .env profile and sets default profile logs root" do
    parent = self()

    deps =
      deps(parent,
        env: %{
          "SYMPHONY_PORT" => "4002"
        }
      )

    assert {:ok, args} = StartCommand.cli_args([profile: "client-a"], deps)

    assert args == [
             StartCommand.ack_flag(),
             "--env-file",
             ".env.client-a",
             "--logs-root",
             "log/client-a",
             "--port",
             "4002",
             "WORKFLOW.md"
           ]

    assert_received {:load_env, env_path}
    assert Path.basename(env_path) == ".env.client-a"
  end

  test "explicit options override profile defaults" do
    parent = self()

    assert {:ok, args} =
             StartCommand.cli_args(
               [
                 profile: "client-a",
                 env_file: "runner.env",
                 logs_root: "custom-log",
                 port: 4010,
                 workflow: "custom/WORKFLOW.md"
               ],
               deps(parent)
             )

    assert args == [
             StartCommand.ack_flag(),
             "--env-file",
             "runner.env",
             "--logs-root",
             "custom-log",
             "--port",
             "4010",
             "custom/WORKFLOW.md"
           ]
  end

  test "can read workflow and logs root from env after preload" do
    parent = self()

    deps =
      deps(parent,
        env: %{
          "SYMPHONY_WORKFLOW" => "from-env/WORKFLOW.md",
          "SYMPHONY_LOGS_ROOT" => "from-env-log"
        }
      )

    assert {:ok, args} = StartCommand.cli_args([], deps)

    assert args == [
             StartCommand.ack_flag(),
             "--logs-root",
             "from-env-log",
             "--port",
             "4000",
             "from-env/WORKFLOW.md"
           ]
  end

  test "rejects invalid profile names and invalid env port values" do
    assert {:error, message} = StartCommand.cli_args([profile: "../bad"], deps(self()))
    assert message =~ "profile may contain only"

    assert {:error, message} =
             StartCommand.cli_args(
               [],
               deps(self(), env: %{"SYMPHONY_PORT" => "not-a-port"})
             )

    assert message =~ "SYMPHONY_PORT"
  end

  test "returns env preload errors" do
    assert {:error, message} =
             StartCommand.cli_args(
               [env_file: "missing.env"],
               deps(self(), load_env_file: fn _path -> {:error, :enoent} end)
             )

    assert message =~ "failed to load missing.env"
  end

  defp deps(parent, opts \\ []) do
    env = Keyword.get(opts, :env, %{})
    load_env_file = Keyword.get(opts, :load_env_file)

    %{
      get_env: fn key -> Map.get(env, key) end,
      load_env_file:
        load_env_file ||
          fn path ->
            send(parent, {:load_env, path})
            :ok
          end,
      load_env_file_if_present: fn path ->
        send(parent, {:load_env_if_present, path})
        :ok
      end
    }
  end
end
