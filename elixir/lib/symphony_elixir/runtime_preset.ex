defmodule SymphonyElixir.RuntimePreset do
  @moduledoc """
  Entr'acte-facing app-server runtime preset helpers.

  These presets select the command branch in the default `WORKFLOW.md`; they do
  not own backend behavior. Backend adaptation remains in the selected runtime
  command, such as Sari.
  """

  @type id :: String.t()
  @type kind :: :codex | :sari
  @type preset :: %{
          required(:id) => id(),
          required(:kind) => kind(),
          optional(:sari_preset) => String.t()
        }

  @presets %{
    "codex/app_server" => %{id: "codex/app_server", kind: :codex},
    "sari/fake" => %{id: "sari/fake", kind: :sari, sari_preset: "fake"},
    "sari/claude_code" => %{id: "sari/claude_code", kind: :sari, sari_preset: "claude_code"},
    "sari/opencode_lmstudio" => %{
      id: "sari/opencode_lmstudio",
      kind: :sari,
      sari_preset: "opencode_lmstudio"
    }
  }

  @aliases %{
    "codex" => "codex/app_server",
    "codex_app_server" => "codex/app_server",
    "app_server" => "codex/app_server",
    "sari" => "sari/claude_code",
    "sari/claude" => "sari/claude_code",
    "claude" => "sari/claude_code",
    "claude_code" => "sari/claude_code",
    "sari/opencode" => "sari/opencode_lmstudio",
    "opencode" => "sari/opencode_lmstudio",
    "opencode_lmstudio" => "sari/opencode_lmstudio",
    "fake" => "sari/fake"
  }

  @spec default_id() :: id()
  def default_id, do: "codex/app_server"

  @spec known_ids() :: [id()]
  def known_ids, do: Map.keys(@presets) |> Enum.sort()

  @spec normalize(String.t() | atom() | nil) :: {:ok, id()} | {:error, term()}
  def normalize(nil), do: {:ok, default_id()}

  def normalize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize()
  end

  def normalize(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" ->
        {:error, :blank_runtime_preset}

      Map.has_key?(@presets, normalized) ->
        {:ok, normalized}

      alias_id = Map.get(@aliases, normalized) ->
        {:ok, alias_id}

      true ->
        {:error, {:unknown_runtime_preset, value, known_ids()}}
    end
  end

  @spec get(String.t() | atom() | nil) :: {:ok, preset()} | {:error, term()}
  def get(value) do
    with {:ok, id} <- normalize(value) do
      {:ok, Map.fetch!(@presets, id)}
    end
  end

  @spec codex?(String.t() | atom() | nil) :: boolean()
  def codex?(value) do
    case get(value) do
      {:ok, %{kind: :codex}} -> true
      _ -> false
    end
  end

  @spec sari?(String.t() | atom() | nil) :: boolean()
  def sari?(value) do
    case get(value) do
      {:ok, %{kind: :sari}} -> true
      _ -> false
    end
  end
end
