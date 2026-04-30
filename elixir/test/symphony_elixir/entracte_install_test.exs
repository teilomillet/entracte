defmodule Mix.Tasks.Entracte.InstallTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "entracte-install-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "installed launcher starts this checkout with defaults", %{tmp_dir: tmp_dir} do
    launcher = install_launcher!(tmp_dir)
    home = Path.join(tmp_dir, "checkout")
    File.mkdir_p!(home)
    stub = write_mise_stub!(tmp_dir)

    {output, status} =
      System.cmd(launcher, ["start"],
        env: launcher_env(stub, tmp_dir, home),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert captured_args(tmp_dir) == ["exec", "--", "mix", "symphony.start"]
    assert captured_pwd(tmp_dir) == physical_path(home)
  end

  test "installed launcher forwards bootstrap arguments", %{tmp_dir: tmp_dir} do
    launcher = install_launcher!(tmp_dir)
    home = Path.join(tmp_dir, "checkout")
    File.mkdir_p!(home)
    stub = write_mise_stub!(tmp_dir)

    {output, status} =
      System.cmd(launcher, ["bootstrap", "--runtime", "sari/claude_code", "--sari-bin", "/opt/sari"],
        env: launcher_env(stub, tmp_dir, home),
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert captured_args(tmp_dir) == [
             "exec",
             "--",
             "mix",
             "symphony.bootstrap",
             "--runtime",
             "sari/claude_code",
             "--sari-bin",
             "/opt/sari"
           ]

    assert captured_pwd(tmp_dir) == physical_path(home)
  end

  test "installed launcher delegates setup to the root launcher", %{tmp_dir: tmp_dir} do
    launcher = install_launcher!(tmp_dir)
    home = Path.join([tmp_dir, "checkout", "elixir"])
    root_launcher = Path.join([tmp_dir, "checkout", "entracte"])
    File.mkdir_p!(home)

    File.write!(root_launcher, """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\\n' "$@" > "$CAPTURE_ARGS"
    printf '%s\\n' "$PWD" > "$CAPTURE_PWD"
    """)

    File.chmod!(root_launcher, 0o755)

    {output, status} =
      System.cmd(launcher, ["setup", "--yes", "--skip-bootstrap"],
        env: launcher_env("", tmp_dir, home),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert captured_args(tmp_dir) == ["setup", "--yes", "--skip-bootstrap"]
  end

  test "installed launcher keeps profile-file compatibility", %{tmp_dir: tmp_dir} do
    launcher = install_launcher!(tmp_dir)
    home = Path.join(tmp_dir, "checkout")
    profile_dir = Path.join(tmp_dir, "profiles")
    File.mkdir_p!(home)
    File.mkdir_p!(profile_dir)

    profile_path = Path.join(profile_dir, "runner.toml")

    File.write!(profile_path, """
    [runner]
    workflow = "WORKFLOW.custom.md"
    env_file = ".env.custom"
    logs_root = "log/custom"
    port = 4100
    """)

    stub = write_mise_stub!(tmp_dir)

    {output, status} =
      System.cmd(launcher, ["start", profile_path],
        env: launcher_env(stub, tmp_dir, home),
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert captured_args(tmp_dir) == [
             "exec",
             "--",
             "mix",
             "symphony.start",
             "--workflow",
             Path.join(physical_path(profile_dir), "WORKFLOW.custom.md"),
             "--env-file",
             Path.join(physical_path(profile_dir), ".env.custom"),
             "--logs-root",
             Path.join(physical_path(profile_dir), "log/custom"),
             "--port",
             "4100"
           ]
  end

  defp install_launcher!(tmp_dir) do
    bin_dir = Path.join(tmp_dir, "bin")

    capture_io(fn ->
      Mix.Task.rerun("entracte.install", ["--bin-dir", bin_dir])
    end)

    Path.join(bin_dir, "entracte")
  end

  defp write_mise_stub!(tmp_dir) do
    stub_dir = Path.join(tmp_dir, "stub-bin")
    File.mkdir_p!(stub_dir)

    stub_path = Path.join(stub_dir, "mise")

    File.write!(stub_path, """
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\\n' "$@" > "$CAPTURE_ARGS"
    printf '%s\\n' "$PWD" > "$CAPTURE_PWD"
    """)

    File.chmod!(stub_path, 0o755)
    stub_dir
  end

  defp launcher_env(stub_dir, tmp_dir, home) do
    [
      {"PATH", stub_dir <> ":" <> System.get_env("PATH", "")},
      {"CAPTURE_ARGS", Path.join(tmp_dir, "args.txt")},
      {"CAPTURE_PWD", Path.join(tmp_dir, "pwd.txt")},
      {"ENTRACTE_HOME", home}
    ]
  end

  defp captured_args(tmp_dir) do
    tmp_dir
    |> Path.join("args.txt")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp captured_pwd(tmp_dir) do
    tmp_dir
    |> Path.join("pwd.txt")
    |> File.read!()
    |> String.trim()
  end

  defp physical_path(path) do
    {resolved, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(resolved)
  end
end
