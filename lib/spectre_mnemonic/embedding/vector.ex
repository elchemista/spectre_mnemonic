defmodule SpectreMnemonic.Embedding.Vector do
  @moduledoc """
  Vettore-backed dense-vector and packed-signature compatibility helpers.

  Dense vectors are normalized into little-endian f32 binaries for storage.
  Packed signatures are bitstrings stored as binaries and compared with
  Hamming distance.

  Lists and f32 binaries require only Vettore. The historical tensor helpers
  remain available when the host application independently installs Nx, but
  SpectreMnemonic itself does not depend on Nx.
  """

  @type vector_input :: binary() | [number()] | term()

  @vettore_vector Module.concat(["Vettore", "Vector"])
  @vettore_nx Module.concat(["Vettore", "Interop", "Nx"])
  @nx Module.concat(["Nx"])
  @nx_tensor Module.concat(["Nx", "Tensor"])
  @f32_max 3.402_823_466_385_288_6e38

  @doc "Converts a list, f32 binary, or host-provided tensor to little-endian f32."
  @spec to_f32_binary(vector_input() | term()) :: binary() | nil
  def to_f32_binary(vector) do
    with {:ok, values} <- validated_list(vector),
         true <- values != [] do
      case vettore_call(:to_f32_binary, [vector]) do
        {:ok, binary} when is_binary(binary) -> binary
        :unavailable -> encode_f32(values)
        _error -> nil
      end
    else
      _error -> nil
    end
  end

  @doc "Converts a little-endian f32 binary, list, or host tensor to a float list."
  @spec to_list(vector_input() | nil | term()) :: [float()]
  def to_list(vector) do
    case validated_list(vector) do
      {:ok, values} when values != [] -> values
      _error -> []
    end
  end

  @doc """
  Converts a vector into an Nx tensor when Nx is installed by the host.

  This compatibility function returns `{:error, :nx_not_available}` when the
  host does not provide Nx.
  """
  @spec to_tensor(vector_input() | term()) ::
          term() | {:error, :nx_not_available | :invalid_vector}
  def to_tensor(vector) do
    with {:ok, values} <- validated_list(vector),
         true <- values != [] do
      case vettore_call(:to_nx, [vector]) do
        {:ok, tensor} -> tensor
        {:error, :nx_not_available} -> {:error, :nx_not_available}
        :unavailable -> nx_from_list(values)
        _error -> {:error, :invalid_vector}
      end
    else
      _error -> {:error, :invalid_vector}
    end
  end

  @doc "Returns the flattened vector dimension count."
  @spec dimensions(vector_input() | term()) :: non_neg_integer()
  def dimensions(vector) do
    case validated_list(vector) do
      {:ok, values} -> length(values)
      _error -> 0
    end
  end

  @doc "Normalizes a vector to unit length and returns a list."
  @spec normalize(vector_input() | term()) :: [float()]
  def normalize(vector) do
    with {:ok, values} <- validated_list(vector),
         true <- values != [] do
      normalize_as_list(vector, values)
    else
      _error -> []
    end
  end

  @doc """
  Normalizes a vector and returns an Nx tensor when the host provides Nx.

  Kept temporarily for source compatibility; new internal code uses f32
  binaries through Vettore instead.
  """
  @spec normalize_tensor(vector_input() | term()) ::
          term() | {:error, :nx_not_available | :invalid_vector}
  def normalize_tensor(vector) do
    with {:ok, values} <- validated_list(vector),
         true <- values != [] do
      case vettore_call(:normalize, [vector, :l2, [as: :nx]]) do
        {:ok, tensor} -> tensor
        {:error, :nx_not_available} -> {:error, :nx_not_available}
        :unavailable -> values |> normalize_with_distance() |> nx_from_list()
        _error -> {:error, :invalid_vector}
      end
    else
      _error -> {:error, :invalid_vector}
    end
  end

  @doc "Normalizes a vector and returns its persisted little-endian f32 form."
  @spec normalize_to_f32_binary(vector_input() | term()) :: binary() | nil
  def normalize_to_f32_binary(vector) do
    with {:ok, values} <- validated_list(vector),
         true <- values != [] do
      case vettore_call(:normalize, [vector, :l2, [as: :f32_binary]]) do
        {:ok, binary} when is_binary(binary) -> binary
        :unavailable -> values |> normalize_with_distance() |> encode_f32()
        _error -> nil
      end
    else
      _error -> nil
    end
  end

  @doc "Computes a dot product for equally sized vectors."
  @spec dot(vector_input(), vector_input()) :: float()
  def dot(left, right) do
    case vettore_call(:dot_product, [left, right]) do
      {:ok, value} when is_number(value) -> value * 1.0
      :unavailable -> distance_metric(:inner_product, left, right)
      _error -> 0.0
    end
  end

  @doc "Computes cosine similarity for equally sized vectors."
  @spec cosine(vector_input(), vector_input()) :: float()
  def cosine(left, right) do
    case vettore_call(:cosine, [left, right]) do
      {:ok, value} when is_number(value) -> value * 1.0
      :unavailable -> distance_metric(:cosine, left, right)
      _error -> 0.0
    end
  end

  @doc "Counts set bits in a byte."
  @spec popcount(0..255) :: non_neg_integer()
  def popcount(byte) when is_integer(byte) and byte >= 0 and byte <= 255 do
    byte = byte - Bitwise.band(Bitwise.bsr(byte, 1), 0x55)
    byte = Bitwise.band(byte, 0x33) + Bitwise.band(Bitwise.bsr(byte, 2), 0x33)
    Bitwise.band(byte + Bitwise.bsr(byte, 4), 0x0F)
  end

  @doc "Computes Hamming distance between two equally sized packed binaries."
  @spec hamming_distance(term(), term()) :: non_neg_integer() | :infinity
  def hamming_distance(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      hamming_distance_bytes(left, right, 0)
    else
      :infinity
    end
  end

  def hamming_distance(_left, _right), do: :infinity

  @doc "Returns Hamming similarity in the 0.0..1.0 range."
  @spec hamming_similarity(term(), term(), non_neg_integer() | nil) :: float()
  def hamming_similarity(left, right, bits \\ nil) do
    distance = hamming_distance(left, right)
    bit_count = comparable_bit_count(bits, left, right)

    cond do
      distance == :infinity -> 0.0
      bit_count <= 0 -> 0.0
      true -> max(0.0, 1.0 - distance / bit_count)
    end
  end

  defp validated_list(vector) do
    case vettore_call(:to_list, [vector]) do
      {:ok, values} when is_list(values) -> validate_fallback_list(values)
      :unavailable -> fallback_to_list(vector)
      _error -> {:error, :invalid_vector}
    end
  end

  defp fallback_to_list(vector) when is_list(vector), do: validate_fallback_list(vector)

  defp fallback_to_list(vector) when is_binary(vector) do
    if byte_size(vector) > 0 and rem(byte_size(vector), 4) == 0 and finite_f32_binary?(vector) do
      {:ok, for(<<value::little-float-32 <- vector>>, do: value)}
    else
      {:error, :invalid_vector}
    end
  end

  defp fallback_to_list(vector) do
    if tensor?(vector) and nx_available?() do
      vector
      |> apply_nx(:to_flat_list, [])
      |> validate_fallback_list()
    else
      {:error, :invalid_vector}
    end
  rescue
    _exception -> {:error, :invalid_vector}
  end

  defp validate_fallback_list(values) when is_list(values) do
    if Enum.all?(values, &finite_f32?/1) do
      {:ok, Enum.map(values, &(&1 / 1))}
    else
      {:error, :invalid_vector}
    end
  end

  defp validate_fallback_list(_values), do: {:error, :invalid_vector}

  defp finite_f32?(value) when is_integer(value), do: abs(value) <= @f32_max

  defp finite_f32?(value) when is_float(value) do
    value >= -@f32_max and value <= @f32_max
  end

  defp finite_f32?(_value), do: false

  defp finite_f32_binary?(<<>>), do: true

  defp finite_f32_binary?(<<bits::little-unsigned-32, rest::binary>>) do
    Bitwise.band(bits, 0x7F800000) != 0x7F800000 and finite_f32_binary?(rest)
  end

  defp normalize_as_list(vector, values) do
    case vettore_call(:normalize, [vector, :l2, [as: :list]]) do
      {:ok, normalized} -> normalized
      _error -> normalize_with_distance(values)
    end
  end

  defp normalize_with_distance(values) do
    case Vettore.Distance.normalize(values, :l2) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> []
    end
  end

  defp distance_metric(metric, left, right) do
    with {:ok, left} <- validated_list(left),
         {:ok, right} <- validated_list(right),
         true <- left != [] and length(left) == length(right),
         {:ok, value} <- apply(Vettore.Distance, metric, [left, right]) do
      value * 1.0
    else
      _error -> 0.0
    end
  end

  defp encode_f32(values) do
    for value <- values, into: <<>>, do: <<value::float-little-32>>
  end

  defp nx_from_list(values) do
    if nx_available?() do
      # Dynamic dispatch preserves tensor compatibility without an Nx dependency.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(@nx, :tensor, [values, [type: :f32]])
    else
      {:error, :nx_not_available}
    end
  rescue
    _exception -> {:error, :invalid_vector}
  end

  defp apply_nx(tensor, function, args), do: apply(@nx, function, [tensor | args])

  defp nx_available? do
    case optional_call(@vettore_nx, :available?, []) do
      true -> true
      _other -> Code.ensure_loaded?(@nx) and function_exported?(@nx, :tensor, 2)
    end
  end

  defp tensor?(%{__struct__: struct} = vector) do
    case optional_call(@vettore_nx, :tensor?, [vector]) do
      true -> true
      _other -> struct == @nx_tensor
    end
  end

  defp tensor?(_vector), do: false

  defp vettore_call(function, args), do: optional_call(@vettore_vector, function, args)

  defp optional_call(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      :unavailable
    end
  rescue
    _exception -> {:error, :invalid_vector}
  catch
    _kind, _reason -> {:error, :invalid_vector}
  end

  defp hamming_distance_bytes(<<>>, <<>>, acc), do: acc

  defp hamming_distance_bytes(<<left, left_rest::binary>>, <<right, right_rest::binary>>, acc) do
    hamming_distance_bytes(left_rest, right_rest, acc + popcount(Bitwise.bxor(left, right)))
  end

  defp comparable_bits(left, right) when is_binary(left) and is_binary(right),
    do: min(byte_size(left) * 8, byte_size(right) * 8)

  defp comparable_bits(_left, _right), do: 0

  defp comparable_bit_count(nil, left, right), do: comparable_bits(left, right)
  defp comparable_bit_count(bits, _left, _right) when is_integer(bits) and bits >= 0, do: bits
  defp comparable_bit_count(_bits, _left, _right), do: 0
end
