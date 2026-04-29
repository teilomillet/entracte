defmodule SymphonyElixir.EnvFileTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.EnvFile

  test "loads dotenv assignments into the process environment" do
    prefix = "SYMP_ENV_FILE_TEST_#{System.unique_integer([:positive])}"
    existing_key = "#{prefix}_EXISTING"
    quoted_key = "#{prefix}_QUOTED"
    single_quoted_key = "#{prefix}_SINGLE_QUOTED"
    empty_key = "#{prefix}_EMPTY"

    restore_on_exit([existing_key, quoted_key, single_quoted_key, empty_key])
    System.put_env(existing_key, "old")

    path =
      write_env_file!("""
      # runner config
      #{existing_key}=new
      export #{quoted_key}="hello\\nworld"
      #{single_quoted_key}='literal # value'
      #{empty_key}=
      """)

    assert :ok = EnvFile.load(path)
    assert System.get_env(existing_key) == "new"
    assert System.get_env(quoted_key) == "hello\nworld"
    assert System.get_env(single_quoted_key) == "literal # value"
    assert System.get_env(empty_key) == ""
  end

  test "can preserve existing environment values when override is disabled" do
    key = "SYMP_ENV_FILE_TEST_KEEP_#{System.unique_integer([:positive])}"
    restore_on_exit([key])
    System.put_env(key, "from-shell")

    path = write_env_file!("#{key}=from-file\n")

    assert :ok = EnvFile.load(path, override: false)
    assert System.get_env(key) == "from-shell"
  end

  test "reports malformed dotenv lines with line context" do
    path = write_env_file!("VALID=value\nnot an assignment\n")

    assert {:error, {:env_file_invalid_line, 2}} = EnvFile.load(path)
  end

  test "reports missing env files for explicit loads" do
    path = Path.join(System.tmp_dir!(), "missing-env-#{System.unique_integer([:positive])}")

    assert {:error, {:env_file_read_failed, ^path, :enoent}} = EnvFile.load(path)
  end

  test "ignores missing env file when using load_if_present" do
    path = Path.join(System.tmp_dir!(), "missing-env-#{System.unique_integer([:positive])}")

    assert :ok = EnvFile.load_if_present(path)
  end

  test "loads present env file when using load_if_present" do
    key = "SYMP_ENV_FILE_TEST_PRESENT_#{System.unique_integer([:positive])}"
    restore_on_exit([key])
    path = write_env_file!("#{key}=present\n")

    assert :ok = EnvFile.load_if_present(path)
    assert System.get_env(key) == "present"
  end

  defp write_env_file!(content) do
    dir = Path.join(System.tmp_dir!(), "symphony-env-file-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, ".env")
    File.write!(path, content)

    on_exit(fn -> File.rm_rf(dir) end)

    path
  end

  defp restore_on_exit(keys) do
    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end
end
