defmodule SymphonyElixir.SecretRedactorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SecretRedactor

  test "redacts secret-like map keys and environment assignments" do
    value = %{
      api_key: "linear-secret",
      nested: %{"PRIVATE-TOKEN" => "gitlab-secret", "message" => "LINEAR_API_KEY=abc123 ok"}
    }

    redacted = SecretRedactor.inspect_redacted(value)

    refute redacted =~ "linear-secret"
    refute redacted =~ "gitlab-secret"
    refute redacted =~ "abc123"
    assert redacted =~ "[REDACTED]"
  end
end
