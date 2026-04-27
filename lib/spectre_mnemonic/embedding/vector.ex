defmodule SpectreMnemonic.Embedding.Vector do
  @moduledoc """
  Nx-backed vector and binary-distance helpers used by embedding and recall.

  Dense vectors are normalized into little-endian f32 binaries for storage.
  Packed signatures are bitstrings stored as binaries and compared with Hamming
  distance. Public helpers accept lists, stored f32 binaries, or Nx tensors.
  """

  @type vector_input :: binary() | [number()] | Nx.Tensor.t()

  @doc "Converts a list or f32 binary into a little-endian f32 binary."
  @spec to_f32_binary(vector_input() | term()) :: binary() | nil
  def to_f32_binary(vector) when is_binary(vector), do: vector

  def to_f32_binary(vector) do
    if tensor?(vector) do
      vector
      |> Nx.as_type(:f32)
      |> Nx.to_binary()
    else
      to_f32_binary_without_nx(vector)
    end
  end

  @spec to_f32_binary_without_nx(term()) :: binary() | nil
  defp to_f32_binary_without_nx(vector) when is_list(vector) do
    vector
    |> Enum.map(&(&1 * 1.0))
    |> Enum.reduce(<<>>, fn value, acc -> <<acc::binary, value::little-float-32>> end)
  end

  defp to_f32_binary_without_nx(_vector), do: nil

  @doc "Converts a little-endian f32 binary or list into a float list."
  @spec to_list(vector_input() | nil | term()) :: [float()]
  def to_list(vector) do
    if tensor?(vector) do
      Nx.to_flat_list(vector)
    else
      to_list_without_nx(vector)
    end
  end

  @spec to_list_without_nx(term()) :: [float()]
  defp to_list_without_nx(vector) when is_list(vector), do: Enum.map(vector, &(&1 * 1.0))
  defp to_list_without_nx(nil), do: []
  defp to_list_without_nx(<<>>), do: []

  defp to_list_without_nx(binary) when is_binary(binary) do
    for <<value::little-float-32 <- binary>>, do: value
  end

  defp to_list_without_nx(_vector), do: []

  @doc "Converts a little-endian f32 binary, list, or tensor into an Nx tensor."
  @spec to_tensor(vector_input()) :: term() | {:error, :nx_not_available}
  def to_tensor(vector) do
    if nx_available?() do
      cond do
        tensor?(vector) -> Nx.as_type(vector, :f32)
        is_binary(vector) -> Nx.from_binary(vector, :f32)
        is_list(vector) -> Nx.tensor(vector, type: :f32)
        true -> Nx.tensor([], type: :f32)
      end
    else
      {:error, :nx_not_available}
    end
  end

  @doc "Returns vector dimensions."
  @spec dimensions(vector_input() | term()) :: non_neg_integer()
  def dimensions(vector) do
    cond do
      tensor?(vector) ->
        vector
        |> Nx.shape()
        |> Tuple.product()

      is_list(vector) ->
        length(vector)

      is_binary(vector) ->
        div(byte_size(vector), 4)

      true ->
        0
    end
  end

  @doc "Normalizes a vector to unit length, preserving list representation."
  @spec normalize([number()] | term()) :: [float()]
  def normalize(vector) do
    if nx_available?() do
      vector
      |> normalize_tensor()
      |> Nx.to_flat_list()
    else
      normalize_without_nx(vector)
    end
  end

  @doc "Normalizes a vector to unit length and returns an Nx tensor."
  @spec normalize_tensor(vector_input() | term()) :: term()
  def normalize_tensor(vector) do
    tensor = to_tensor(vector)

    if match?({:error, :nx_not_available}, tensor) do
      {:error, :nx_not_available}
    else
      norm = Nx.LinAlg.norm(tensor)

      if Nx.to_number(norm) == 0.0 do
        Nx.as_type(tensor, :f32)
      else
        Nx.divide(tensor, norm)
      end
    end
  end

  @spec normalize_without_nx(term()) :: [float()]
  defp normalize_without_nx(vector) when is_list(vector) do
    norm = norm(vector)

    if norm == 0.0 do
      Enum.map(vector, &(&1 * 1.0))
    else
      Enum.map(vector, &(&1 / norm))
    end
  end

  defp normalize_without_nx(vector), do: vector |> to_list_without_nx() |> normalize_without_nx()

  @doc "Normalizes a vector and returns a f32 binary."
  @spec normalize_to_f32_binary(vector_input() | term()) :: binary() | nil
  def normalize_to_f32_binary(vector) do
    if nx_available?() do
      vector
      |> normalize_tensor()
      |> to_f32_binary()
    else
      vector
      |> to_list_without_nx()
      |> normalize_without_nx()
      |> to_f32_binary_without_nx()
    end
  end

  @doc "Computes dot product for equally sized vectors."
  @spec dot(vector_input(), vector_input()) :: float()
  def dot(left, right) do
    if nx_available?() do
      dot_with_nx(left, right)
    else
      dot_without_nx(left, right)
    end
  end

  @doc "Computes cosine similarity for equally sized vectors."
  @spec cosine(vector_input(), vector_input()) :: float()
  def cosine(left, right) do
    if nx_available?() do
      cosine_with_nx(left, right)
    else
      cosine_without_nx(left, right)
    end
  end

  @spec dot_with_nx(vector_input(), vector_input()) :: float()
  defp dot_with_nx(left, right) do
    left_tensor = to_tensor(left)
    right_tensor = to_tensor(right)

    if same_shape?(left_tensor, right_tensor) and dimensions(left_tensor) > 0 do
      left_tensor
      |> Nx.multiply(right_tensor)
      |> Nx.sum()
      |> Nx.to_number()
    else
      0.0
    end
  end

  @spec cosine_with_nx(vector_input(), vector_input()) :: float()
  defp cosine_with_nx(left, right) do
    left_tensor = to_tensor(left)
    right_tensor = to_tensor(right)

    if same_shape?(left_tensor, right_tensor) and dimensions(left_tensor) > 0 do
      left_norm = Nx.LinAlg.norm(left_tensor)
      right_norm = Nx.LinAlg.norm(right_tensor)

      if Nx.to_number(left_norm) == 0.0 or Nx.to_number(right_norm) == 0.0 do
        0.0
      else
        Nx.multiply(left_tensor, right_tensor)
        |> Nx.sum()
        |> Nx.divide(Nx.multiply(left_norm, right_norm))
        |> Nx.to_number()
      end
    else
      0.0
    end
  end

  @spec dot_without_nx(vector_input(), vector_input()) :: float()
  defp dot_without_nx(left, right) do
    left = to_list_without_nx(left)
    right = to_list_without_nx(right)

    if length(left) == length(right) and left != [] do
      Enum.zip(left, right)
      |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    else
      0.0
    end
  end

  @spec cosine_without_nx(vector_input(), vector_input()) :: float()
  defp cosine_without_nx(left, right) do
    left = to_list_without_nx(left)
    right = to_list_without_nx(right)

    if length(left) == length(right) and left != [] do
      left_norm = norm(left)
      right_norm = norm(right)

      if left_norm == 0.0 or right_norm == 0.0 do
        0.0
      else
        dot_without_nx(left, right) / (left_norm * right_norm)
      end
    else
      0.0
    end
  end

  @spec same_shape?(term(), term()) :: boolean()
  defp same_shape?({:error, :nx_not_available}, _right), do: false
  defp same_shape?(_left, {:error, :nx_not_available}), do: false
  defp same_shape?(left, right), do: Nx.shape(left) == Nx.shape(right)

  @spec nx_available? :: boolean()
  defp nx_available? do
    Code.ensure_loaded?(Nx) and function_exported?(Nx, :tensor, 2)
  end

  @spec tensor?(term()) :: boolean()
  defp tensor?(%Nx.Tensor{}), do: nx_available?()
  defp tensor?(_vector), do: false

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
