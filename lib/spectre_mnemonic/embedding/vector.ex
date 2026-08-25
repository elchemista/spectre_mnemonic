defmodule SpectreMnemonic.Embedding.Vector do
  @moduledoc """
  Vettore-backed dense-vector and packed-signature compatibility helpers.

  Dense vectors are normalized into little-endian f32 binaries for storage.
  Packed signatures are bitstrings stored as binaries and compared with
  Hamming distance.

  All dense conversion, validation, normalization, and metrics delegate to
  `Vettore.Vector`. The historical tensor helpers remain available through
  Vettore's runtime-only Nx interoperability when the host independently
  installs Nx; SpectreMnemonic itself does not depend on Nx.
  """

  @type vector_input :: binary() | [number()] | term()

  @doc "Converts a list, f32 binary, or host-provided tensor to little-endian f32."
  @spec to_f32_binary(vector_input() | term()) :: binary() | nil
  def to_f32_binary(vector) do
    with {:ok, dimensions} <- Vettore.Vector.dimensions(vector),
         true <- dimensions > 0,
         {:ok, binary} <- Vettore.Vector.to_f32_binary(vector) do
      binary
    else
      _error -> nil
    end
  end

  @doc "Converts a little-endian f32 binary, list, or host tensor to a float list."
  @spec to_list(vector_input() | nil | term()) :: [float()]
  def to_list(vector) do
    case Vettore.Vector.to_list(vector) do
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
    with {:ok, dimensions} <- Vettore.Vector.dimensions(vector),
         true <- dimensions > 0,
         {:ok, tensor} <- Vettore.Vector.to_nx(vector) do
      tensor
    else
      {:error, :nx_not_available} = error -> error
      _error -> {:error, :invalid_vector}
    end
  end

  @doc "Returns the flattened vector dimension count."
  @spec dimensions(vector_input() | term()) :: non_neg_integer()
  def dimensions(vector) do
    case Vettore.Vector.to_list(vector) do
      {:ok, values} -> length(values)
      _error -> 0
    end
  end

  @doc "Normalizes a vector to unit length and returns a list."
  @spec normalize(vector_input() | term()) :: [float()]
  def normalize(vector) do
    with {:ok, dimensions} <- Vettore.Vector.dimensions(vector),
         true <- dimensions > 0,
         {:ok, normalized} <- Vettore.Vector.normalize(vector, :l2, as: :list) do
      normalized
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
    with {:ok, dimensions} <- Vettore.Vector.dimensions(vector),
         true <- dimensions > 0,
         {:ok, tensor} <- Vettore.Vector.normalize(vector, :l2, as: :nx) do
      tensor
    else
      {:error, :nx_not_available} = error -> error
      _error -> {:error, :invalid_vector}
    end
  end

  @doc "Normalizes a vector and returns its persisted little-endian f32 form."
  @spec normalize_to_f32_binary(vector_input() | term()) :: binary() | nil
  def normalize_to_f32_binary(vector) do
    with {:ok, dimensions} <- Vettore.Vector.dimensions(vector),
         true <- dimensions > 0,
         {:ok, binary} <- Vettore.Vector.normalize(vector, :l2, as: :f32_binary) do
      binary
    else
      _error -> nil
    end
  end

  @doc "Computes a dot product for equally sized vectors."
  @spec dot(vector_input(), vector_input()) :: float()
  def dot(left, right) do
    case Vettore.Vector.dot_product(left, right) do
      {:ok, value} when is_number(value) -> value * 1.0
      _error -> 0.0
    end
  end

  @doc "Computes cosine similarity for equally sized vectors."
  @spec cosine(vector_input(), vector_input()) :: float()
  def cosine(left, right) do
    case Vettore.Vector.cosine(left, right) do
      {:ok, value} when is_number(value) -> value * 1.0
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
