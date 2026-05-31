defmodule SpectreMnemonic.Persistence.Store.FileFrame do
  @moduledoc """
  Encodes and decodes append-only file store frames.

  The file adapter owns paths and writes. This module owns the durable frame
  format so the binary protocol can be tested and changed independently.
  """

  @magic "SMEM"
  @version 1
  @header_bytes byte_size(@magic) + 1 + 8 + 8 + 4 + 4

  @type t :: {pos_integer(), integer(), term()}
  @type fold_fun(acc) :: (t(), acc -> {:cont, acc} | {:halt, acc})

  @doc "Encodes one storage payload into the append-only frame format."
  @spec encode(pos_integer(), term(), integer()) :: binary()
  def encode(seq, payload, timestamp \\ System.system_time(:millisecond))
      when is_integer(seq) and seq > 0 and is_integer(timestamp) do
    encoded_payload = :erlang.term_to_binary(payload, [:compressed])
    crc = :erlang.crc32(encoded_payload)

    <<@magic, @version, seq::unsigned-64, timestamp::signed-64, byte_size(encoded_payload)::32,
      crc::32, encoded_payload::binary>>
  end

  @doc """
  Reads frames from an IO device until EOF, corruption, or the fold asks to halt.
  """
  @spec read_frames(File.io_device(), acc, fold_fun(acc)) :: acc when acc: term()
  def read_frames(io, acc, fun) when is_function(fun, 2) do
    case IO.binread(io, @header_bytes) do
      <<@magic, @version, seq::unsigned-64, timestamp::signed-64, len::32, crc::32>> ->
        read_payload(io, seq, timestamp, len, crc, acc, fun)

      incomplete_or_unknown when is_binary(incomplete_or_unknown) ->
        acc

      :eof ->
        acc

      {:error, _reason} ->
        acc
    end
  end

  @spec read_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          acc,
          fold_fun(acc)
        ) :: acc
        when acc: term()
  defp read_payload(io, seq, timestamp, len, crc, acc, fun) do
    case IO.binread(io, len) do
      payload when is_binary(payload) and byte_size(payload) == len ->
        read_complete_payload(io, seq, timestamp, payload, crc, acc, fun)

      _incomplete_or_error ->
        acc
    end
  end

  @spec read_complete_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          binary(),
          non_neg_integer(),
          acc,
          fold_fun(acc)
        ) :: acc
        when acc: term()
  defp read_complete_payload(io, seq, timestamp, payload, crc, acc, fun) do
    if :erlang.crc32(payload) == crc do
      continue_frame(io, {seq, timestamp, :erlang.binary_to_term(payload)}, acc, fun)
    else
      acc
    end
  end

  @spec continue_frame(File.io_device(), t(), acc, fold_fun(acc)) :: acc when acc: term()
  defp continue_frame(io, frame, acc, fun) do
    case fun.(frame, acc) do
      {:cont, acc} -> read_frames(io, acc, fun)
      {:halt, acc} -> acc
    end
  end
end
