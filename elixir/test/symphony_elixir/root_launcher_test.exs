defmodule EntrActe.RootLauncherTest do
  use ExUnit.Case, async: false

  test "setup wrapper enables the global launcher by default" do
    setup_script = Path.join(repo_root(), "setup")

    assert File.regular?(setup_script)
    assert File.read!(setup_script) =~ "--install-launcher"

    assert {output, 0} =
             System.cmd(setup_script, ["--help"], stderr_to_stdout: true)

    assert output =~ "usage: ./setup"
    assert output =~ "Guided first-time setup"
    assert output =~ "codex/app_server"
    assert output =~ "sari/claude_code"
    assert output =~ "sari/opencode_lmstudio"
    assert output =~ "sari/fake"
  end

  test "root make install delegates to guided setup" do
    tmp_dir = Path.join(System.tmp_dir!(), "entracte-root-launcher-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    fake_elixir_dir = Path.join(tmp_dir, "elixir")
    File.mkdir_p!(fake_elixir_dir)
    File.write!(Path.join(fake_elixir_dir, ".env.example"), "LINEAR_API_KEY=\n")

    stub_dir = write_mise_stub!(tmp_dir)

    {output, status} =
      System.cmd(
        "make",
        [
          "install",
          "ARGS=--yes --skip-bootstrap"
        ],
        cd: repo_root(),
        env: [
          {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
          {"CAPTURE_COMMANDS", Path.join(tmp_dir, "commands.txt")},
          {"ENTRACTE_HOME", fake_elixir_dir},
          {"ENTRACTE_SETUP_YES", "1"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "./setup --yes --skip-bootstrap"

    commands = captured_commands(tmp_dir)
    assert Enum.any?(commands, &String.ends_with?(&1, " :: exec -- mix setup"))
    assert Enum.any?(commands, &String.ends_with?(&1, " :: exec -- mix build"))
    assert Enum.any?(commands, &String.ends_with?(&1, " :: exec -- mix entracte.install --force"))
  end

  test "setup command runs the toolchain setup without requiring mix on PATH" do
    tmp_dir = Path.join(System.tmp_dir!(), "entracte-root-launcher-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    stub_dir = write_mise_stub!(tmp_dir)
    launcher = Path.join(repo_root(), "entracte")

    {output, status} =
      System.cmd(launcher, ["setup", "--yes", "--skip-bootstrap"],
        env: [
          {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
          {"CAPTURE_COMMANDS", Path.join(tmp_dir, "commands.txt")},
          {"ENTRACTE_SETUP_YES", "1"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    commands = captured_commands(tmp_dir)
    assert Enum.any?(commands, &String.ends_with?(&1, " :: trust"))
    assert Enum.any?(commands, &String.ends_with?(&1, " :: install"))
    assert Enum.any?(commands, &String.ends_with?(&1, " :: exec -- mix setup"))
    assert Enum.any?(commands, &String.ends_with?(&1, " :: exec -- mix build"))
    assert output =~ "Skipped tracker bootstrap."
    assert output =~ "./entracte start"
  end

  test "setup command forwards OpenCode runtime aliases with the Sari binary" do
    tmp_dir = Path.join(System.tmp_dir!(), "entracte-root-launcher-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    fake_elixir_dir = Path.join(tmp_dir, "elixir")
    File.mkdir_p!(fake_elixir_dir)
    File.write!(Path.join(fake_elixir_dir, ".env.example"), "LINEAR_API_KEY=\n")

    stub_dir = write_mise_stub!(tmp_dir)
    launcher = Path.join(repo_root(), "entracte")

    {output, status} =
      System.cmd(
        launcher,
        [
          "setup",
          "--yes",
          "--runtime",
          "opencode",
          "--sari-bin",
          "/opt/sari/scripts/sari_app_server",
          "--linear-api-key",
          "lin_api_key",
          "--project",
          "https://linear.app/teilo/project/sellerie-f26dbad5798d/overview"
        ],
        env: [
          {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
          {"CAPTURE_COMMANDS", Path.join(tmp_dir, "commands.txt")},
          {"ENTRACTE_HOME", fake_elixir_dir},
          {"ENTRACTE_SETUP_YES", "1"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert Enum.any?(captured_commands(tmp_dir), fn command ->
             String.ends_with?(
               command,
               " :: exec -- mix symphony.bootstrap --runtime opencode --project sellerie-f26dbad5798d --sari-bin /opt/sari/scripts/sari_app_server"
             )
           end)
  end

  test "root launcher forwards daemon commands" do
    tmp_dir = Path.join(System.tmp_dir!(), "entracte-root-launcher-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    fake_elixir_dir = Path.join(tmp_dir, "elixir")
    File.mkdir_p!(fake_elixir_dir)

    stub_dir = write_mise_stub!(tmp_dir)
    launcher = Path.join(repo_root(), "entracte")

    {output, status} =
      System.cmd(launcher, ["daemon", "status", "--name", "anef"],
        env: [
          {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
          {"CAPTURE_COMMANDS", Path.join(tmp_dir, "commands.txt")},
          {"ENTRACTE_HOME", fake_elixir_dir}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert Enum.any?(captured_commands(tmp_dir), fn command ->
             String.ends_with?(command, " :: exec -- mix symphony.daemon status --name anef")
           end)
  end

  defp write_mise_stub!(tmp_dir) do
    stub_dir = Path.join(tmp_dir, "stub-bin")
    File.mkdir_p!(stub_dir)

    stub_path = Path.join(stub_dir, "mise")

    File.write!(stub_path, """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s :: %s\\n' "$PWD" "$*" >> "$CAPTURE_COMMANDS"
    """)

    File.chmod!(stub_path, 0o755)
    stub_dir
  end

  defp captured_commands(tmp_dir) do
    tmp_dir
    |> Path.join("commands.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp repo_root do
    Path.expand("../../..", __DIR__)
  end
end
