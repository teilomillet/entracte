defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime.{Headless, WorkspaceGuard}

  test "headless runner executes a configured command in the issue workspace with prompt on stdin" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-runtime-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-HEADLESS")
      runner = Path.join(test_root, "fake-headless")
      trace_file = Path.join(test_root, "headless.trace")
      prompt_copy = trace_file <> ".prompt"

      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      printf 'PWD:%s\\n' "$PWD" > #{trace_file}
      printf 'PROMPT_FILE:%s\\n' "$SYMPHONY_AGENT_PROMPT_FILE" >> #{trace_file}
      test -f "$SYMPHONY_AGENT_PROMPT_FILE" || exit 7
      cat > #{prompt_copy}
      printf 'headless command completed\\n'
      """)

      File.chmod!(runner, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_runner: "headless",
        headless_command: runner
      )

      issue = %Issue{
        id: "issue-headless-runtime",
        identifier: "MT-HEADLESS",
        title: "Validate headless runtime",
        description: "Ensure headless runners receive prompts in the issue workspace",
        state: "In Progress",
        url: "https://example.org/issues/MT-HEADLESS",
        labels: ["backend"]
      }

      prompt = "Fix the issue\nwith multiple lines."
      parent = self()
      ref = make_ref()
      on_message = fn message -> send(parent, {ref, message}) end

      assert {:ok, session} = AgentRuntime.start_session(workspace)
      assert %Headless.Session{} = session
      assert {:ok, result} = AgentRuntime.run_turn(session, prompt, issue, on_message: on_message)

      assert result.result == :turn_completed
      assert result.session_id =~ "headless-"
      assert result.output =~ "headless command completed"

      assert_receive {^ref, %{event: :session_started, session_id: session_id, agent_runtime_pid: runtime_pid}}
      assert is_binary(runtime_pid)
      assert_receive {^ref, %{event: :headless_output, payload: %{"method" => "headless/output"}}}
      assert_receive {^ref, %{event: :turn_completed, session_id: ^session_id}}

      assert File.read!(prompt_copy) == prompt

      trace = File.read!(trace_file)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert trace =~ "PWD:#{canonical_workspace}\n"
      [prompt_file_line] = Regex.run(~r/PROMPT_FILE:(.+)\n/, trace, capture: :all_but_first)
      assert String.starts_with?(prompt_file_line, canonical_workspace)
      refute File.exists?(prompt_file_line)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runtime dispatches explicit app-server session structs" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-runtime-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-APP-SESSION")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-runtime"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-runtime"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-app-server-runtime-session",
        identifier: "MT-APP-SESSION",
        title: "Validate app-server runtime session",
        description: "Ensure AgentRuntime dispatches explicit app-server session structs",
        state: "In Progress",
        url: "https://example.org/issues/MT-APP-SESSION",
        labels: ["backend"]
      }

      parent = self()
      ref = make_ref()
      on_message = fn message -> send(parent, {ref, message}) end

      assert {:ok, session} = AgentRuntime.start_session(workspace)
      assert %AppServer.Session{} = session
      assert {:ok, result} = AgentRuntime.run_turn(session, "App-server prompt", issue, on_message: on_message)

      assert result.session_id == "thread-runtime-turn-runtime"
      assert result.thread_id == "thread-runtime"
      assert result.turn_id == "turn-runtime"

      assert_receive {^ref, %{event: :session_started, session_id: "thread-runtime-turn-runtime"}}
      assert_receive {^ref, %{event: :turn_completed}}

      AgentRuntime.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner launches over ssh in the issue workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-remote-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      remote_workspace = Path.join([test_root, "remote-workspaces", "MT-REMOTE-HEADLESS"])
      fake_ssh = Path.join(test_root, "ssh")
      runner = Path.join(test_root, "fake-headless")
      trace_file = Path.join(test_root, "headless-ssh.trace")
      prompt_copy = trace_file <> ".prompt"

      File.mkdir_p!(remote_workspace)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-headless-ssh.trace}"
      remote_command=""
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      for arg do
        remote_command="$arg"
      done

      eval "$remote_command"
      """)

      File.write!(runner, """
      #!/bin/sh
      printf 'PWD:%s\\n' "$PWD" >> #{trace_file}
      printf 'PROMPT_FILE:%s\\n' "$SYMPHONY_AGENT_PROMPT_FILE" >> #{trace_file}
      test -f "$SYMPHONY_AGENT_PROMPT_FILE" || exit 7
      cat > #{prompt_copy}
      printf 'remote headless command completed\\n'
      """)

      File.chmod!(fake_ssh, 0o755)
      File.chmod!(runner, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(test_root, "remote-workspaces"),
        agent_runner: "headless",
        headless_command: runner
      )

      issue = %Issue{
        id: "issue-remote-headless-runtime",
        identifier: "MT-REMOTE-HEADLESS",
        title: "Validate remote headless runtime",
        description: "Ensure ssh-backed headless runners run inside the issue workspace",
        state: "In Progress",
        url: "https://example.org/issues/MT-REMOTE-HEADLESS",
        labels: ["backend"]
      }

      prompt = "Fix the remote issue\nusing 100% of the headless runner."

      assert {:ok, session} = AgentRuntime.start_session(remote_workspace, worker_host: "worker-01:2200")
      assert {:ok, result} = AgentRuntime.run_turn(session, prompt, issue)

      assert result.result == :turn_completed
      assert result.output =~ "remote headless command completed"
      assert File.read!(prompt_copy) == prompt

      trace = File.read!(trace_file)
      assert trace =~ "-T -p 2200 worker-01 bash -lc"
      assert trace =~ "cd "
      assert trace =~ remote_workspace
      assert trace =~ "PWD:#{remote_workspace}\n"

      [prompt_file_line] = Regex.run(~r/PROMPT_FILE:(.+)\n/, trace, capture: :all_but_first)
      assert String.starts_with?(prompt_file_line, remote_workspace)
      refute File.exists?(prompt_file_line)
    after
      File.rm_rf(test_root)
    end
  end

  test "headless remote runner rejects prompts too large for a shell command argument" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-remote-prompt-limit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      prompt = String.duplicate("x", 128 * 1024 + 1)
      issue = headless_issue("MT-HEADLESS-REMOTE-LIMIT")
      parent = self()
      ref = make_ref()
      on_message = fn message -> send(parent, {ref, message}) end

      assert {:error, {:remote_prompt_too_large, prompt_bytes, max_bytes}} =
               workspace
               |> headless_session("true")
               |> Map.put(:worker_host, "worker-01")
               |> Headless.run_turn(prompt, issue, on_message: on_message)

      assert prompt_bytes == byte_size(prompt)
      assert max_bytes == 128 * 1024

      assert_receive {^ref,
                      %{
                        event: :startup_failed,
                        reason: {:remote_prompt_too_large, ^prompt_bytes, ^max_bytes}
                      }}
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner uses the shared workspace guard" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      runner = Path.join(test_root, "fake-headless")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.write!(runner, "#!/bin/sh\n")
      File.chmod!(runner, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_runner: "headless",
        headless_command: runner
      )

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AgentRuntime.start_session(workspace_root)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AgentRuntime.start_session(outside_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "headless timeout bounds total command runtime instead of idle output time" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-HEADLESS-TIMEOUT")
      runner = Path.join(test_root, "fake-headless-timeout")

      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      printf 'tick-1\\n'
      sleep 0.08
      printf 'tick-2\\n'
      sleep 0.08
      printf 'tick-3\\n'
      sleep 0.3
      printf 'late\\n'
      """)

      File.chmod!(runner, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_runner: "headless",
        headless_command: runner,
        headless_timeout_ms: 200
      )

      issue = %Issue{
        id: "issue-headless-timeout",
        identifier: "MT-HEADLESS-TIMEOUT",
        title: "Validate headless timeout",
        description: "Ensure output does not reset the command deadline",
        state: "In Progress",
        url: "https://example.org/issues/MT-HEADLESS-TIMEOUT",
        labels: ["backend"]
      }

      assert {:ok, session} = AgentRuntime.start_session(workspace)

      started_at = System.monotonic_time(:millisecond)
      assert {:error, :headless_timeout} = AgentRuntime.run_turn(session, "timeout prompt", issue)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < 400
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runtime surfaces unsupported runners and stops headless sessions" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_runner: "unsupported")

    assert {:error, {:unsupported_agent_runner, "unsupported"}} =
             AgentRuntime.start_session("/unused-workspace")

    assert :ok = AgentRuntime.stop_session(headless_session("/unused-workspace"))
    assert :ok = AgentRuntime.stop_session(%{agent_runtime: :headless})
    assert :ok = AgentRuntime.stop_session(%{agent_runtime: :app_server})

    shell = System.find_executable("sh") || System.find_executable("bash")
    port = Port.open({:spawn_executable, String.to_charlist(shell)}, [:binary, args: [~c"-c", ~c"sleep 1"]])

    assert :ok = AgentRuntime.stop_session(%{agent_runtime: :app_server, port: port, stale_field: :ignored})
  end

  test "agent runtime rejects malformed and unknown runtime sessions instead of falling back to app server" do
    issue = headless_issue("MT-UNKNOWN-RUNTIME")

    assert {:error, :invalid_app_server_session} =
             AgentRuntime.run_turn(%{agent_runtime: :app_server}, "prompt", issue)

    assert {:error, :invalid_headless_session} =
             AgentRuntime.run_turn(%{agent_runtime: :headless}, "prompt", issue)

    assert {:error, {:unsupported_agent_runtime, :future_runner}} =
             AgentRuntime.run_turn(%{agent_runtime: :future_runner}, "prompt", issue)

    assert {:error, :missing_agent_runtime} =
             AgentRuntime.run_turn(%{}, "prompt", issue)

    assert {:error, :missing_agent_runtime} =
             AgentRuntime.run_turn(%{workspace: "/legacy-map"}, "prompt", issue)

    assert {:error, :invalid_agent_runtime_session} =
             AgentRuntime.run_turn(:not_a_session, "prompt", issue)

    assert {:error, :invalid_agent_runtime_session} =
             AgentRuntime.run_turn([:not_a_session], "prompt", issue)

    assert {:error, :invalid_app_server_session} =
             AppServer.Session
             |> struct()
             |> AgentRuntime.run_turn("prompt", issue)

    assert {:error, :invalid_headless_session} =
             Headless.Session
             |> struct()
             |> AgentRuntime.run_turn("prompt", issue)
  end

  test "headless runner direct defaults report missing bash and prompt write failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-startup-failures-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace = Path.join(test_root, "workspace")
      missing_workspace = Path.join(test_root, "missing-workspace")
      File.mkdir_p!(workspace)

      issue = headless_issue("MT-HEADLESS-STARTUP")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        agent_runner: "headless",
        headless_command: "true"
      )

      assert {:ok, session} = Headless.start_session(workspace)
      assert session.command == "true"

      System.put_env("PATH", "")

      assert {:error, :bash_not_found} =
               Headless.run_turn(headless_session(workspace), "prompt", issue)

      restore_env("PATH", previous_path)

      parent = self()
      ref = make_ref()
      on_message = fn message -> send(parent, {ref, message}) end

      assert {:error, :enoent} =
               Headless.run_turn(headless_session(missing_workspace), "prompt", issue, on_message: on_message)

      assert_receive {^ref, %{event: :startup_failed, reason: :enoent}}
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner keeps partial output received before exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-partial-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      runner = Path.join(test_root, "fake-headless-partial-output")
      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      printf 'partial-output'
      sleep 0.1
      """)

      File.chmod!(runner, 0o755)

      assert {:ok, %{output: "partial-output"}} =
               Headless.run_turn(headless_session(workspace, runner), "prompt", headless_issue("MT-HEADLESS-PARTIAL"))
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner captures partial oversized output on nonzero exit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-output-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      runner = Path.join(test_root, "fake-headless-large-output")
      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      i=0
      while [ "$i" -lt 10001 ]; do
        printf 'xxxxxxxxxx'
        i=$((i + 1))
      done
      exit 17
      """)

      File.chmod!(runner, 0o755)

      parent = self()
      ref = make_ref()
      on_message = fn message -> send(parent, {ref, message}) end

      assert {:error, {:headless_exit, 17}} =
               Headless.run_turn(headless_session(workspace, runner), "prompt", headless_issue("MT-HEADLESS-FAIL"), on_message: on_message)

      assert_receive {^ref, %{event: :headless_output, payload: %{"text" => output_event_text}}}
      assert byte_size(output_event_text) == 1_014
      assert String.ends_with?(output_event_text, "...[truncated]")

      assert_receive {^ref, %{event: :turn_ended_with_error, raw: raw_output}}
      assert byte_size(raw_output) == 100_000
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner treats an expired deadline as a timeout" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-expired-deadline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      runner = Path.join(test_root, "fake-headless-sleep")
      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      sleep 1
      """)

      File.chmod!(runner, 0o755)

      assert {:error, :headless_timeout} =
               Headless.run_turn(headless_session(workspace, runner, 0), "prompt", headless_issue("MT-HEADLESS-DEADLINE"))
    after
      File.rm_rf(test_root)
    end
  end

  test "headless runner stops a silent command when the receive timeout expires" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-silent-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      runner = Path.join(test_root, "fake-headless-silent-timeout")
      File.mkdir_p!(workspace)

      File.write!(runner, """
      #!/bin/sh
      sleep 1
      """)

      File.chmod!(runner, 0o755)

      assert {:error, :headless_timeout} =
               Headless.run_turn(headless_session(workspace, runner, 50), "prompt", headless_issue("MT-HEADLESS-SILENT-TIMEOUT"))
    after
      File.rm_rf(test_root)
    end
  end

  test "headless port metadata tolerates closed ports without an os pid" do
    shell = System.find_executable("sh") || System.find_executable("bash")

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(shell)},
        [:binary, :exit_status, args: [~c"-c", ~c"true"]]
      )

    Port.close(port)

    assert Headless.port_metadata_for_test(port, nil) == %{}
    assert Headless.port_metadata_for_test(port, "worker-01") == %{worker_host: "worker-01"}
  end

  test "workspace guard reports unreadable local paths and empty remote workspaces" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-headless-guard-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      locked_parent = Path.join(workspace_root, "locked")
      unreadable_workspace = Path.join(locked_parent, "MT-LOCKED")

      File.mkdir_p!(locked_parent)
      File.chmod!(locked_parent, 0)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, ^unreadable_workspace, reason}} =
               WorkspaceGuard.validate_workspace_cwd(unreadable_workspace, nil)

      assert reason in [:eacces, :eperm]

      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "worker-01"}} =
               WorkspaceGuard.validate_workspace_cwd(" ", "worker-01")
    after
      File.chmod(Path.join([test_root, "workspaces", "locked"]), 0o755)
      File.rm_rf(test_root)
    end
  end

  defp headless_session(workspace, command \\ "true", timeout_ms \\ 1_000) do
    %Headless.Session{
      command: command,
      timeout_ms: timeout_ms,
      workspace: workspace,
      worker_host: nil
    }
  end

  defp headless_issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Validate headless runtime branch coverage",
      description: "Exercise a specific headless runtime branch",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["backend"]
    }
  end
end
