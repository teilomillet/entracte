defmodule SymphonyElixir.RuntimePresetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimePreset

  test "normalizes canonical presets, aliases, atoms, and nil" do
    assert RuntimePreset.default_id() == "codex/app_server"
    assert "codex/app_server" in RuntimePreset.known_ids()
    assert "sari/claude_code" in RuntimePreset.known_ids()

    assert RuntimePreset.normalize(nil) == {:ok, "codex/app_server"}
    assert RuntimePreset.normalize(:claude_code) == {:ok, "sari/claude_code"}
    assert RuntimePreset.normalize(" SARI/Claude_Code ") == {:ok, "sari/claude_code"}
    assert RuntimePreset.normalize("app_server") == {:ok, "codex/app_server"}
    assert RuntimePreset.normalize("opencode") == {:ok, "sari/opencode_lmstudio"}
    assert RuntimePreset.normalize("fake") == {:ok, "sari/fake"}
  end

  test "reports blank and unknown presets" do
    assert RuntimePreset.normalize(" ") == {:error, :blank_runtime_preset}

    assert {:error, {:unknown_runtime_preset, "future", known_ids}} = RuntimePreset.normalize("future")
    assert "codex/app_server" in known_ids
  end

  test "returns preset metadata and predicate helpers" do
    assert RuntimePreset.get("codex") == {:ok, %{id: "codex/app_server", kind: :codex}}

    assert RuntimePreset.get("sari/opencode") ==
             {:ok,
              %{
                id: "sari/opencode_lmstudio",
                kind: :sari,
                sari_preset: "opencode_lmstudio"
              }}

    assert {:error, :blank_runtime_preset} = RuntimePreset.get("")

    assert RuntimePreset.codex?("codex")
    refute RuntimePreset.codex?("sari/claude_code")
    refute RuntimePreset.codex?("unknown")

    assert RuntimePreset.sari?("sari/claude_code")
    refute RuntimePreset.sari?("codex/app_server")
    refute RuntimePreset.sari?("unknown")
  end
end
