defmodule SpectreMnemonic.JSON do
  @moduledoc """
  Runtime boundary for the host application's JSON implementation.

  SpectreMnemonic does not start or own a JSON library. Configure a module that
  exports `decode/1` and either `encode/1` or `encode!/1`:

      config :spectre_mnemonic, json_library: JSON

  Elixir's built-in `JSON` module needs no dependency. Jason and compatible
  third-party implementations can be selected by the host instead; Jason is an
  optional Mix dependency and is never required by SpectreMnemonic itself.
  """

  @type error ::
          :json_library_not_configured
          | {:invalid_json_library, term()}
          | {:json_library_not_available, module()}
          | {:json_function_not_available, module(), atom(), arity()}
          | {:json_library_failure, module(), term()}
          | term()

  @doc "Returns the configured, loaded JSON library."
  @spec library() :: {:ok, module()} | {:error, error()}
  def library do
    case Application.fetch_env(:spectre_mnemonic, :json_library) do
      {:ok, module} when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module),
          do: {:ok, module},
          else: {:error, {:json_library_not_available, module}}

      {:ok, invalid} ->
        {:error, {:invalid_json_library, invalid}}

      :error ->
        {:error, :json_library_not_configured}
    end
  end

  @doc "Encodes a value with the configured JSON library."
  @spec encode(term()) :: {:ok, binary()} | {:error, error()}
  def encode(value) do
    with {:ok, module} <- encoder_library() do
      encode_with(module, value)
    end
  end

  @doc "Encodes a value or raises `ArgumentError` for configuration/adapter errors."
  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, json_error_message(reason)
    end
  end

  @doc "Decodes a JSON binary with the configured JSON library."
  @spec decode(binary()) :: {:ok, term()} | {:error, error()}
  def decode(value) when is_binary(value) do
    with {:ok, module} <- decoder_library() do
      normalize_decode(module, invoke(module, :decode, [value]))
    end
  end

  def decode(_value), do: {:error, :invalid_json_input}

  @doc false
  @spec ensure_encoder() :: :ok | {:error, error()}
  def ensure_encoder do
    with {:ok, _module} <- encoder_library(), do: :ok
  end

  @doc false
  @spec ensure_decoder() :: :ok | {:error, error()}
  def ensure_decoder do
    with {:ok, _module} <- decoder_library(), do: :ok
  end

  @doc false
  @spec ensure_available() :: :ok | {:error, error()}
  def ensure_available do
    with :ok <- ensure_encoder(), do: ensure_decoder()
  end

  @spec encoder_library() :: {:ok, module()} | {:error, error()}
  defp encoder_library do
    with {:ok, module} <- library() do
      if function_exported?(module, :encode, 1) or function_exported?(module, :encode!, 1),
        do: {:ok, module},
        else: {:error, {:json_function_not_available, module, :encode, 1}}
    end
  end

  @spec decoder_library() :: {:ok, module()} | {:error, error()}
  defp decoder_library do
    with {:ok, module} <- library() do
      if function_exported?(module, :decode, 1),
        do: {:ok, module},
        else: {:error, {:json_function_not_available, module, :decode, 1}}
    end
  end

  @spec encode_with(module(), term()) :: {:ok, binary()} | {:error, error()}
  defp encode_with(module, value) do
    cond do
      function_exported?(module, :encode, 1) ->
        normalize_encode(module, invoke(module, :encode, [value]))

      function_exported?(module, :encode!, 1) ->
        normalize_encode(module, invoke(module, :encode!, [value]))

      true ->
        {:error, {:json_function_not_available, module, :encode, 1}}
    end
  end

  @spec invoke(module(), atom(), [term()]) :: term()
  defp invoke(module, function, args) do
    apply(module, function, args)
  rescue
    exception -> {:spectre_json_exception, exception}
  catch
    kind, reason -> {:spectre_json_catch, kind, reason}
  end

  @spec normalize_encode(module(), term()) :: {:ok, binary()} | {:error, error()}
  defp normalize_encode(_module, {:ok, encoded}), do: to_binary(encoded)
  defp normalize_encode(_module, {:error, reason}), do: {:error, reason}

  defp normalize_encode(module, {:spectre_json_exception, exception}),
    do: {:error, {:json_library_failure, module, exception}}

  defp normalize_encode(module, {:spectre_json_catch, kind, reason}),
    do: {:error, {:json_library_failure, module, {kind, reason}}}

  defp normalize_encode(_module, encoded), do: to_binary(encoded)

  @spec normalize_decode(module(), term()) :: {:ok, term()} | {:error, error()}
  defp normalize_decode(_module, {:ok, decoded}), do: {:ok, decoded}
  defp normalize_decode(_module, {:error, reason}), do: {:error, reason}

  defp normalize_decode(module, {:spectre_json_exception, exception}),
    do: {:error, {:json_library_failure, module, exception}}

  defp normalize_decode(module, {:spectre_json_catch, kind, reason}),
    do: {:error, {:json_library_failure, module, {kind, reason}}}

  defp normalize_decode(module, unexpected),
    do: {:error, {:json_library_failure, module, {:unexpected_result, unexpected}}}

  @spec to_binary(term()) :: {:ok, binary()} | {:error, term()}
  defp to_binary(encoded) do
    {:ok, IO.iodata_to_binary(encoded)}
  rescue
    _exception -> {:error, :invalid_json_encoding}
  end

  @spec json_error_message(error()) :: binary()
  defp json_error_message(reason),
    do: "SpectreMnemonic JSON encoding failed: #{inspect(reason)}"
end
