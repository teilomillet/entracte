defmodule Mix.Tasks.Entracte.Install do
  use Mix.Task

  @shortdoc "Installs the entracte launcher into a user bin directory"

  @moduledoc """
  Installs a small `entracte` launcher that starts Symphony from this checkout
  with repo defaults or from TOML runner profiles.

      mix entracte.install
      mix entracte.install --bin-dir ~/.local/bin --force

  The generated launcher keeps this checkout as the runtime source:

      entracte
      entracte start
      entracte check
      entracte bootstrap
      entracte bootstrap --runtime sari/claude_code --sari-bin /path/to/sari/scripts/sari_app_server
      entracte start /path/to/runner.toml
      entracte check /path/to/runner.toml

  For backwards compatibility, `entracte /path/to/runner.toml` starts that
  profile. Profile files use a `[runner]` table:

      [runner]
      workflow = "WORKFLOW.anef.md"
      env_file = "../.env.anef"
      logs_root = "../log/anef"
      port = 4000

  Profile paths are resolved relative to the profile file. The profile argument
  itself is resolved relative to the directory where `entracte` is invoked.
  """

  @switches [bin_dir: :string, force: :boolean, dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    if argv != [] or invalid != [] do
      Mix.raise("Usage: mix entracte.install [--bin-dir path] [--force] [--dry-run]")
    end

    project_dir = Path.dirname(Mix.Project.project_file()) |> Path.expand()
    bin_dir = opts |> Keyword.get(:bin_dir, default_bin_dir()) |> Path.expand()
    launcher_path = Path.join(bin_dir, "entracte")
    launcher = launcher_script(project_dir)

    if Keyword.get(opts, :dry_run, false) do
      Mix.shell().info("Would install entracte launcher to #{launcher_path}")
    else
      install_launcher!(launcher_path, launcher, Keyword.get(opts, :force, false))
      maybe_print_path_hint(bin_dir)
    end
  end

  defp default_bin_dir do
    Path.join(System.user_home!(), ".local/bin")
  end

  defp install_launcher!(launcher_path, launcher, force?) do
    if File.exists?(launcher_path) and not force? do
      Mix.raise("#{launcher_path} already exists. Re-run with --force to replace it.")
    end

    launcher_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(launcher_path, launcher)
    File.chmod!(launcher_path, 0o755)

    Mix.shell().info("Installed entracte launcher to #{launcher_path}")
  end

  defp maybe_print_path_hint(bin_dir) do
    path_entries =
      "PATH"
      |> System.get_env("")
      |> String.split(path_separator(), trim: true)
      |> Enum.map(&Path.expand/1)

    unless Path.expand(bin_dir) in path_entries do
      Mix.shell().info("Add #{bin_dir} to PATH to run `entracte` from any directory.")
    end
  end

  defp path_separator do
    case :os.type() do
      {:win32, _name} -> ";"
      _other -> ":"
    end
  end

  defp launcher_script(project_dir) do
    escaped_project_dir = shell_single_quote(project_dir)

    """
    #!/usr/bin/env bash
    set -euo pipefail

    ENTRACTE_HOME=${ENTRACTE_HOME:-#{escaped_project_dir}}

    case "${1:-}" in
      bootstrap)
        shift || true
        cd -P "$ENTRACTE_HOME"
        if command -v mise >/dev/null 2>&1; then
          exec mise exec -- mix symphony.bootstrap "$@"
        fi
        exec mix symphony.bootstrap "$@"
        ;;
      -h|--help|help)
        echo "usage: entracte [start|check|bootstrap] [profile.toml|bootstrap args...]" >&2
        exit 0
        ;;
    esac

    mode="start"
    profile_arg=""

    case "$#" in
      0)
        ;;
      1)
        case "$1" in
          start)
            ;;
          check)
            mode="check"
            ;;
          -h|--help|help)
            echo "usage: entracte [start|check|bootstrap] [profile.toml|bootstrap args...]" >&2
            exit 0
            ;;
          *)
            profile_arg="$1"
            ;;
        esac
        ;;
      2)
        case "$1" in
          start|check)
            mode="$1"
            profile_arg="$2"
            ;;
          *)
            echo "usage: entracte [start|check|bootstrap] [profile.toml|bootstrap args...]" >&2
            exit 2
            ;;
        esac
        ;;
      *)
        echo "usage: entracte [start|check|bootstrap] [profile.toml|bootstrap args...]" >&2
        exit 2
        ;;
    esac

    CALLER_CWD="$(pwd -P)"

    python3 - "$mode" "$profile_arg" "$ENTRACTE_HOME" "$CALLER_CWD" <<'PY'
    import os
    import pathlib
    import shutil
    import sys

    mode = sys.argv[1]
    profile_arg = sys.argv[2]
    entracte_home = pathlib.Path(sys.argv[3])
    caller_cwd = pathlib.Path(sys.argv[4])

    def parse_profile(text):
        data = {}
        section = None
        for raw_line in text.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                name = line[1:-1].strip()
                section = data.setdefault(name, {})
                continue
            if "=" not in line:
                raise SystemExit("invalid profile line: " + raw_line)
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if value.startswith('"') and value.endswith('"'):
                parsed = value[1:-1]
            else:
                try:
                    parsed = int(value)
                except ValueError:
                    parsed = value
            target = section if section is not None else data
            target[key] = parsed
        return data

    if profile_arg:
        profile_path = pathlib.Path(profile_arg).expanduser()
        if not profile_path.is_absolute():
            profile_path = (caller_cwd / profile_path).resolve()
        data = parse_profile(profile_path.read_text())
        runner = data.get("runner", data)
        base = profile_path.parent
    else:
        runner = {}
        base = entracte_home

    def path_value(key):
        value = runner.get(key)
        if not value:
            return None
        path = pathlib.Path(str(value)).expanduser()
        if not path.is_absolute():
            path = (base / path).resolve()
        return str(path)

    task = "symphony.check" if mode == "check" else "symphony.start"

    if shutil.which("mise"):
        args = ["mise", "exec", "--", "mix", task]
    else:
        args = ["mix", task]

    workflow = path_value("workflow")
    env_file = path_value("env_file")
    logs_root = path_value("logs_root")
    port = runner.get("port")

    if workflow:
        args += ["--workflow", workflow]
    if env_file:
        args += ["--env-file", env_file]
    if mode == "start" and logs_root:
        args += ["--logs-root", logs_root]
    if mode == "start" and port:
        args += ["--port", str(port)]

    os.chdir(entracte_home)
    os.execvp(args[0], args)
    PY
    """
  end

  defp shell_single_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
