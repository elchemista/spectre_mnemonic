defmodule SpectreMnemonic.Embedding.Vector do
  @moduledoc """
  Vector and binary-distance helpers used by embedding and recall.

  Dense vectors are normalized into little-endian f32 binaries for storage.
  Packed signatures are bitstrings stored as binaries and compared with Hamming
  distance.
  """

  @type vector_input :: binary() | [number()]

  @doc "Converts a list or f32 binary into a little-endian f32 binary."
  @spec to_f32_binary(vector_input() | term()) :: binary() | nil
  def to_f32_binary(vector) when is_binary(vector), do: vector

  def to_f32_binary(vector) when is_list(vector) do
    vector
    |> Enum.map(&(&1 * 1.0))
    |> Enum.reduce(<<>>, fn value, acc -> <<acc::binary, value::little-float-32>> end)
  end

  def to_f32_binary(_vector), do: nil

  @doc "Converts a little-endian f32 binary or list into a float list."
  @spec to_list(vector_input() | nil | term()) :: [float()]
  def to_list(vector) when is_list(vector), do: Enum.map(vector, &(&1 * 1.0))
  def to_list(nil), do: []
  def to_list(<<>>), do: []

  def to_list(binary) when is_binary(binary) do
    for <<value::little-float-32 <- binary>>, do: value
  end

  @doc "Returns vector dimensions."
  @spec dimensions(vector_input() | term()) :: non_neg_integer()
  def dimensions(vector) when is_list(vector), do: length(vector)
  def dimensions(vector) when is_binary(vector), do: div(byte_size(vector), 4)
  def dimensions(_vector), do: 0

  @doc "Normalizes a vector to unit length, preserving list representation."
  @spec normalize([number()]) :: [float()]
  def normalize(vector) when is_list(vector) do
    norm = norm(vector)

    if norm == 0.0 do
      Enum.map(vector, &(&1 * 1.0))
    else
      Enum.map(vector, &(&1 / norm))
    end
  end

  @doc "Normalizes a vector and returns a f32 binary."
  @spec normalize_to_f32_binary(vector_input() | term()) :: binary() | nil
  def normalize_to_f32_binary(vector) do
    vector
    |> to_list()
    |> normalize()
    |> to_f32_binary()
  end

  @doc "Builds an Nx tensor when Nx is available."
  @spec to_tensor(vector_input()) :: term() | {:error, :nx_not_available}
  def to_tensor(vector) do
    if Code.ensure_loaded?(Nx) and function_exported?(Nx, :tensor, 2) do
      Nx.tensor(to_list(vector), type: :f32)
    else
      {:error, :nx_not_available}
    end
  end

  @doc "Computes dot product for equally sized vectors."
  @spec dot(vector_input(), vector_input()) :: float()
  def dot(left, right) do
    left = to_list(left)
    right = to_list(right)

    if length(left) == length(right) and left != [] do
      Enum.zip(left, right)
      |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    else
      0.0
    end
  end

  @doc "Computes cosine similarity for equally sized vectors."
  @spec cosine(vector_input(), vector_input()) :: float()
  def cosine(left, right) do
    left = to_list(left)
    right = to_list(right)

    if length(left) == length(right) and left != [] do
      left_norm = norm(left)
      right_norm = norm(right)

      if left_norm == 0.0 or right_norm == 0.0 do
        0.0
      else
        dot(left, right) / (left_norm * right_norm)
      end
    else
      0.0
    end
  end

  @doc "Counts set bits in a byte."
  @spec popcount(0..255) :: non_neg_integer()
  def popcount(byte) when is_integer(byte) and byte >= 0 and byte <= 255 do
    byte
    |> Integer.digits(2)
    |> Enum.count(&(&1 == 1))
  end

  @doc "Computes Hamming distance between two equally sized packed binaries."
  @spec hamming_distance(term(), term()) :: non_neg_integer() | :infinity
  def hamming_distance(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      left
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(right))
      |> Enum.reduce(0, fn {a, b}, acc -> acc + popcount(Bitwise.bxor(a, b)) end)
    else
      :infinity
    end
  end

  def hamming_distance(_left, _right), do: :infinity

  @doc "Returns Hamming similarity in the 0.0..1.0 range."
  @spec hamming_similarity(term(), term(), non_neg_integer() | nil) :: float()
  def hamming_similarity(left, right, bits \\ nil) do
    distance = hamming_distance(left, right)
    bit_count = bits || min(byte_size(left || <<>>) * 8, byte_size(right || <<>>) * 8)

    cond do
      distance == :infinity -> 0.0
      bit_count <= 0 -> 0.0
      true -> max(0.0, 1.0 - distance / bit_count)
    end
  end

  @spec norm([number()]) :: float()
  defp norm(vector) do
    vector
    |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
    |> :math.sqrt()
  end
end
