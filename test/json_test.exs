defmodule SpectreMnemonic.JSONTest do
  use ExUnit.Case, async: false

  alias SpectreMnemonic.JSON

  setup do
    previous = Application.get_env(:spectre_mnemonic, :json_library)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:spectre_mnemonic, :json_library)
      else
        Application.put_env(:spectre_mnemonic, :json_library, previous)
      end
    end)

    :ok
  end

  test "supports Elixir's dependency-free JSON module" do
    Application.put_env(:spectre_mnemonic, :json_library, Elixir.JSON)

    assert {:ok, Elixir.JSON} = JSON.library()
    assert {:ok, ~s({"answer":42})} = JSON.encode(%{"answer" => 42})
    assert {:ok, %{"answer" => 42}} = JSON.decode(~s({"answer":42}))
  end

  test "supports Jason through the same runtime boundary" do
    Application.put_env(:spectre_mnemonic, :json_library, Jason)

    assert {:ok, Jason} = JSON.library()
    assert JSON.encode!(%{"answer" => 42}) == ~s({"answer":42})
    assert {:ok, %{"answer" => 42}} = JSON.decode(~s({"answer":42}))
  end

  test "accepts compatible libraries that return iodata" do
    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.IodataLibrary)

    assert {:ok, ~s("value")} = JSON.encode("value")
    assert {:ok, %{"decoded" => true}} = JSON.decode("ignored")
  end

  test "reports missing, invalid, unavailable, and incomplete configuration" do
    Application.delete_env(:spectre_mnemonic, :json_library)
    assert {:error, :json_library_not_configured} = JSON.library()
    assert {:error, :json_library_not_configured} = JSON.ensure_available()
    assert_raise ArgumentError, ~r/json_library_not_configured/, fn -> JSON.encode!(%{}) end

    Application.put_env(:spectre_mnemonic, :json_library, "Jason")
    assert {:error, {:invalid_json_library, "Jason"}} = JSON.library()

    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.MissingLibrary)

    assert {:error, {:json_library_not_available, __MODULE__.MissingLibrary}} = JSON.library()

    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.IncompleteLibrary)

    assert {:error, {:json_function_not_available, __MODULE__.IncompleteLibrary, :encode, 1}} =
             JSON.encode(%{})

    assert {:error, {:json_function_not_available, __MODULE__.IncompleteLibrary, :decode, 1}} =
             JSON.decode("{}")
  end

  test "encoder failures remain explicit without accepting invalid output" do
    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.FailingLibrary)

    assert {:error, :refused} = JSON.encode(:refuse)
    assert {:error, :invalid_json_encoding} = JSON.encode(:invalid)

    assert {:error, {:json_library_failure, __MODULE__.FailingLibrary, %RuntimeError{}}} =
             JSON.encode(:raise)

    assert {:error, {:json_library_failure, __MODULE__.FailingLibrary, {:throw, :offline}}} =
             JSON.encode(:throw)
  end

  test "decoder exceptions and unexpected responses cannot become decoded records" do
    Application.put_env(:spectre_mnemonic, :json_library, __MODULE__.FailingLibrary)

    assert {:error, :invalid_json_input} = JSON.decode(:not_a_binary)

    assert {:error, {:json_library_failure, __MODULE__.FailingLibrary, %RuntimeError{}}} =
             JSON.decode("raise")

    assert {:error, {:json_library_failure, __MODULE__.FailingLibrary, {:throw, :offline}}} =
             JSON.decode("throw")

    assert {:error, {:json_library_failure, __MODULE__.FailingLibrary, {:unexpected_result, 42}}} =
             JSON.decode("invalid")
  end

  defmodule FailingLibrary do
    def encode(:refuse), do: {:error, :refused}
    def encode(:invalid), do: {:ok, [%{}]}
    def encode(:raise), do: raise("encoding unavailable")
    def encode(:throw), do: throw(:offline)
    def decode("raise"), do: raise("decoding unavailable")
    def decode("throw"), do: throw(:offline)
    def decode("invalid"), do: 42
  end

  defmodule IodataLibrary do
    @moduledoc false

    def encode("value"), do: {:ok, [?\", "value", ?\"]}
    def decode("ignored"), do: {:ok, %{"decoded" => true}}
  end

  defmodule IncompleteLibrary do
    @moduledoc false
  end
end
