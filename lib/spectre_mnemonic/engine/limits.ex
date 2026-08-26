defmodule SpectreMnemonic.Engine.Limits do
  @moduledoc false

  alias SpectreMnemonic.Embedding.Vector

  @defaults %{
    max_input_bytes: 4 * 1024 * 1024,
    max_metadata_bytes: 256 * 1024,
    max_metadata_depth: 16,
    max_vector_dimensions: 16_384
  }

  @doc false
  @spec validate_input(term(), keyword()) :: :ok | {:error, term()}
  def validate_input(input, opts) do
    with :ok <- within_bytes(:input, input_bytes(input), limit(opts, :max_input_bytes)),
         :ok <- validate_metadata(Keyword.get(opts, :metadata, %{}), opts) do
      validate_embedding(opts)
    end
  rescue
    _exception -> {:error, :mnemonic_input_invalid}
  end

  @doc false
  @spec validate_metadata(term(), keyword()) :: :ok | {:error, term()}
  def validate_metadata(metadata, opts) when is_map(metadata) or is_list(metadata) do
    with :ok <-
           within_bytes(
             :metadata,
             :erlang.external_size(metadata),
             limit(opts, :max_metadata_bytes)
           ) do
      depth = depth(metadata, limit(opts, :max_metadata_depth) + 1)

      if depth <= limit(opts, :max_metadata_depth),
        do: :ok,
        else: {:error, {:mnemonic_limit_exceeded, :max_metadata_depth}}
    end
  end

  def validate_metadata(_metadata, _opts), do: :ok

  @spec validate_embedding(keyword()) :: :ok | {:error, term()}
  defp validate_embedding(opts) do
    embedding = Keyword.get(opts, :embedding) || Keyword.get(opts, :vector)

    vector =
      case embedding do
        %{vector: value} -> value
        %{"vector" => value} -> value
        value -> value
      end

    dimensions = Vector.dimensions(vector)
    maximum = limit(opts, :max_vector_dimensions)

    if dimensions == 0 or dimensions <= maximum,
      do: :ok,
      else: {:error, {:mnemonic_limit_exceeded, :max_vector_dimensions}}
  end

  @spec within_bytes(atom(), non_neg_integer(), pos_integer()) :: :ok | {:error, term()}
  defp within_bytes(_kind, size, maximum) when size <= maximum, do: :ok

  defp within_bytes(kind, _size, _maximum),
    do: {:error, {:mnemonic_limit_exceeded, limit_key(kind)}}

  @spec limit_key(:input | :metadata) :: atom()
  defp limit_key(:input), do: :max_input_bytes
  defp limit_key(:metadata), do: :max_metadata_bytes

  @spec input_bytes(term()) :: non_neg_integer()
  defp input_bytes(input) when is_binary(input), do: byte_size(input)
  defp input_bytes(input), do: :erlang.external_size(input)

  @spec limit(keyword(), atom()) :: pos_integer()
  defp limit(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _missing -> Map.fetch!(@defaults, key)
    end
  end

  @spec depth(term(), non_neg_integer()) :: non_neg_integer()
  defp depth(_term, 0), do: 1
  defp depth(%_struct{}, _remaining), do: 1

  defp depth(term, _remaining) when not is_map(term) and not is_list(term) and not is_tuple(term),
    do: 0

  defp depth(term, remaining) when is_map(term) do
    nested =
      term
      |> Enum.map(fn {key, value} ->
        max(depth(key, remaining - 1), depth(value, remaining - 1))
      end)
      |> Enum.max(fn -> 0 end)

    nested + 1
  end

  defp depth(term, remaining) when is_list(term) do
    term |> Enum.map(&depth(&1, remaining - 1)) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
  end

  defp depth(term, remaining) when is_tuple(term),
    do: term |> Tuple.to_list() |> depth(remaining)
end
