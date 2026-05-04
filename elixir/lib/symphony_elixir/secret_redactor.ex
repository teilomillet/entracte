defmodule SymphonyElixir.SecretRedactor do
  @moduledoc """
  Best-effort redaction for operator-visible errors.

  This is intentionally conservative: it targets common token field names and
  credential-looking environment variables while leaving non-secret diagnostics
  readable enough for local debugging.
  """

  @redacted "[REDACTED]"
  @secret_key_pattern ~r/(api[_-]?key|api[_-]?token|authorization|private[_-]?token|secret|password)/i
  @env_assignment_pattern ~r/((?:LINEAR_API_KEY|GITLAB_API_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|CODEX_API_KEY)\s*=\s*)([^\s]+)/i
  @bearer_pattern ~r/(Bearer\s+)[A-Za-z0-9._~+\/=-]+/i

  @spec redact(term()) :: term()
  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key) do
        {key, @redacted}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(values) when is_list(values), do: Enum.map(values, &redact/1)
  def redact(value) when is_binary(value), do: redact_string(value)
  def redact(value), do: value

  @spec inspect_redacted(term()) :: String.t()
  def inspect_redacted(value) do
    value
    |> redact()
    |> inspect()
    |> redact_string()
  end

  @spec redact_string(String.t()) :: String.t()
  def redact_string(value) when is_binary(value) do
    value
    |> String.replace(@env_assignment_pattern, "\\1#{@redacted}")
    |> String.replace(@bearer_pattern, "\\1#{@redacted}")
  end

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()
  defp secret_key?(key) when is_binary(key), do: Regex.match?(@secret_key_pattern, key)
  defp secret_key?(_key), do: false
end
