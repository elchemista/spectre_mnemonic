defmodule SpectreMnemonic.Embedding.BinaryQuantizer do
  @moduledoc """
  Converts dense vectors into packed binary signatures.

  The quantizer is intentionally simple for v1: positive values become 1 bits,
  non-positive values become 0 bits. The requested signature length is sampled
  proportionally across the source dimensions, so longer signatures preserve the
  vector's shape without storing floats.
  """

  alias SpectreMnemonic.Embedding.Vector

  @default_bits 256

  @doc "Produces a packed binary signature from a dense vector."
  def quantize(vector, opts \\ []) do
    values = Vector.to_list(vector)
    bits = Keyword.get(opts, :bits, @default_bits)

    cond do
      values == [] -> nil
      bits <= 0 -> nil
      true -> values |> sample(bits) |> pack()
    end
  end

  defp sample(values, bits) do
    dimensions = length(values)

    for index <- 0..(bits - 1) do
      source_index = min(dimensions - 1, div(index * dimensions, bits))
      Enum.at(values, source_index) > 0.0
    end
  end

  defp pack(bits) do
    bits
    |> Enum.chunk_every(8, 8, Stream.cycle([false]) |> Enum.take(7))
    |> Enum.reduce(<<>>, fn chunk, acc ->
      byte =
        chunk
        |> Enum.with_index()
        |> Enum.reduce(0, fn
          {true, index}, value -> Bitwise.bor(value, Bitwise.bsl(1, 7 - index))
          {false, _index}, value -> value
        end)

      <<acc::binary, byte>>
    end)
  end
end
