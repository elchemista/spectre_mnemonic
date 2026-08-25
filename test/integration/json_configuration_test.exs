defmodule SpectreMnemonic.Integration.JSONConfigurationTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Export

  setup do
    previous = Application.get_env(:spectre_mnemonic, :json_library)

    on_exit(fn -> Application.put_env(:spectre_mnemonic, :json_library, previous) end)
    :ok
  end

  test "built-in JSON and Jason can verify the same canonical export" do
    scope = {:subject, "json-interchange"}
    path = Path.expand("mnemonic_data/json-interchange.mnemonic")

    Application.put_env(:spectre_mnemonic, :json_library, Elixir.JSON)
    assert {:ok, _memory} = SpectreMnemonic.remember("portable JSON boundary", scope: scope)
    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope)

    Application.put_env(:spectre_mnemonic, :json_library, Jason)
    assert {:ok, decoded} = Export.read(path)
    assert decoded.manifest["namespace"] == "spectre_mnemonic_test"
  end

  test "verification hashes stored JSON bytes instead of the reader encoder output" do
    scope = {:subject, "json-lexical-interchange"}
    path = Path.expand("mnemonic_data/json-lexical-interchange.mnemonic")

    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.EscapedJSON)

    assert {:ok, _memory} =
             SpectreMnemonic.remember("portable café payload",
               scope: scope,
               metadata: %{ratio: 1.0e-20}
             )

    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope, mode: :full)

    Application.put_env(:spectre_mnemonic, :json_library, Jason)
    assert {:ok, decoded} = Export.read(path)

    assert Enum.any?(decoded.nodes, fn node ->
             node["text"] == "portable café payload"
           end)
  end

  test "export and reader fail explicitly when JSON is not configured" do
    scope = {:subject, "json-required"}
    path = Path.expand("mnemonic_data/json-required.mnemonic")

    Application.put_env(:spectre_mnemonic, :json_library, Jason)
    assert {:ok, _report} = SpectreMnemonic.export(path, scope: scope)

    Application.delete_env(:spectre_mnemonic, :json_library)

    assert {:ok, _memory} =
             SpectreMnemonic.remember("core memory remains JSON-free",
               scope: {:subject, "json-free-core"}
             )

    assert {:ok, packet} =
             SpectreMnemonic.recall("JSON-free core",
               scope: {:subject, "json-free-core"}
             )

    assert packet.moments != []

    assert {:error, :json_library_not_configured} =
             SpectreMnemonic.export(path <> ".new", scope: scope)

    assert {:error, :json_library_not_configured} = Export.read(path)
    assert {:error, :json_library_not_configured} = Export.stream(path)
  end

  defmodule EscapedJSON do
    @moduledoc false

    def encode(value) when is_binary(value) do
      encoded = value |> JSON.encode!() |> IO.iodata_to_binary()
      {:ok, String.replace(encoded, "é", "\\u00e9")}
    end

    def encode(value) when is_float(value) do
      {:ok, value |> Float.to_string() |> String.replace("e", "E")}
    end

    def encode(value), do: {:ok, JSON.encode!(value)}
    def decode(value), do: JSON.decode(value)
  end
end
