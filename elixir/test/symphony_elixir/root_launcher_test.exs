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
