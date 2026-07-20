defmodule SpectreMnemonic.Persistence.Store.FileFrame do
  @moduledoc """
  Encodes and decodes append-only file store frames.

  The file adapter owns paths and writes. This module owns the durable frame
  format so the binary protocol can be tested and changed independently.

  Frame layout:

    * `"SMEM"` magic bytes
    * one-byte format version
    * unsigned 64-bit sequence number
    * signed 64-bit millisecond timestamp
    * 32-bit payload byte length
    * 32-bit CRC32 of the encoded payload
    * compressed Erlang term payload

  Replay stops at the first incomplete or corrupt frame. That makes appends
  crash-tolerant: a partial trailing write is ignored instead of poisoning the
  whole log.
  """

  @magic "SMEM"
  @version 1
  @header_bytes byte_size(@magic) + 1 + 8 + 8 + 4 + 4

  @type t :: {pos_integer(), integer(), term()}
  @type fold_fun(acc) :: (t(), acc -> {:cont, acc} | {:halt, acc})

  @doc """
  Encodes one storage payload into the append-only frame format.

  The payload is serialized with `:erlang.term_to_binary/2` and compressed. The
  timestamp argument exists mostly for deterministic tests; production callers
  normally use the default current system time.

  ## Example

      iex> frame = SpectreMnemonic.Persistence.Store.FileFrame.encode(1, {:put, "hello"}, 1_717_000_000_000)
      iex> byte_size(frame) > 0
      true
  """
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

  The fold function receives `{seq, timestamp, payload}` and returns either
  `{:cont, acc}` to keep reading or `{:halt, acc}` to stop early.

  ## Example

      iex> {:ok, io} = StringIO.open(SpectreMnemonic.Persistence.Store.FileFrame.encode(1, :ok))
      iex> SpectreMnemonic.Persistence.Store.FileFrame.read_frames(io, [], fn frame, acc -> {:cont, [frame | acc]} end)
      [{1, _timestamp, :ok}]
  """
  @spec read_frames(File.io_device(), acc, fold_fun(acc)) :: acc when acc: term()
  def read_frames(io, acc, fun) when is_function(fun, 2) do
    # I chose framed append-only storage because the recovery story is boring:
    # read until the bytes stop making sense, then stop. Future work can add
    # better repair tooling; today we do not turn one bad tail into a funeral.
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
      case decode_payload(payload) do
        {:ok, decoded} -> continue_frame(io, {seq, timestamp, decoded}, acc, fun)
        :error -> acc
      end
    else
      acc
    end
  end

  @spec decode_payload(binary()) :: {:ok, term()} | :error
  defp decode_payload(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception -> :error
  end

  @spec continue_frame(File.io_device(), t(), acc, fold_fun(acc)) :: acc when acc: term()
  defp continue_frame(io, frame, acc, fun) do
    case fun.(frame, acc) do
      {:cont, acc} -> read_frames(io, acc, fun)
      {:halt, acc} -> acc
    end
  end
end
