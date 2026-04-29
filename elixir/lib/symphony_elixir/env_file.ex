defmodule SymphonyElixir.EnvFile do
  @moduledoc """
  Loads simple dotenv-style files into the process environment.
  """

  @key_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @type entry :: {String.t(), String.t()}

  @spec load(Path.t(), keyword()) :: :ok | {:error, term()}
  def load(path, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, content} <- File.read(path),
         {:ok, entries} <- parse(content) do
      apply_entries(entries, Keyword.get(opts, :override, true))
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, {:env_file_read_failed, path, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_if_present(Path.t(), keyword()) :: :ok | {:error, term()}
  def load_if_present(path, opts \\ []) when is_binary(path) and is_list(opts) do
    if File.regular?(path) do
      load(path, opts)
    else
      :ok
    end
  end

  @spec parse(String.t()) :: {:ok, [entry()]} | {:error, term()}
  def parse(content) when is_binary(content) do
    content
    |> String.split(~r/\R/, trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_line/2)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_line({line, line_number}, {:ok, entries}) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      {:cont, {:ok, entries}}
    else
      case parse_assignment(trimmed, line_number) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp parse_assignment("export " <> assignment, line_number) do
    assignment
    |> String.trim_leading()
    |> parse_assignment(line_number)
  end

  defp parse_assignment(line, line_number) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        with :ok <- validate_key(key, line_number),
             {:ok, value} <- parse_value(raw_value, line_number) do
          {:ok, {key, value}}
        end

      _ ->
        {:error, {:env_file_invalid_line, line_number}}
    end
  end

  defp validate_key(key, line_number) do
    if Regex.match?(@key_pattern, key) do
      :ok
    else
      {:error, {:env_file_invalid_key, line_number, key}}
    end
  end

  defp parse_value(raw_value, line_number) do
    value = String.trim(raw_value)

    cond do
      quoted?(value, "\"") ->
        value
        |> unquote_value("\"")
        |> unescape_double_quoted_value()
        |> then(&{:ok, &1})

      quoted?(value, "'") ->
        {:ok, unquote_value(value, "'")}

      starts_with_quote?(value) ->
        {:error, {:env_file_unclosed_quote, line_number}}

      true ->
        {:ok, value}
    end
  end

  defp quoted?(value, quote) do
    String.starts_with?(value, quote) and String.ends_with?(value, quote) and String.length(value) >= 2
  end

  defp starts_with_quote?(value), do: String.starts_with?(value, ["\"", "'"])

  defp unquote_value(value, quote) do
    value
    |> String.trim_leading(quote)
    |> String.trim_trailing(quote)
  end

  defp unescape_double_quoted_value(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp apply_entries(entries, override?) do
    Enum.each(entries, fn {key, value} ->
      if override? or is_nil(System.get_env(key)) do
        System.put_env(key, value)
      end
    end)
  end
end
