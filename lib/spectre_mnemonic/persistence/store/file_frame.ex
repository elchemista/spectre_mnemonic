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
  @default_max_payload_bytes 64 * 1024 * 1024

  @type t :: {pos_integer(), integer(), term()}
  @type fold_fun(acc) :: (t(), acc -> {:cont, acc} | {:halt, acc})
  @type scan_status ::
          :clean
          | {:invalid_tail,
             :incomplete_header
             | :unknown_header
             | :payload_too_large
             | :incomplete_payload
             | :crc_mismatch}
  @type scan_result :: %{
          valid_bytes: non_neg_integer(),
          file_bytes: non_neg_integer(),
          last_sequence: non_neg_integer(),
          status: scan_status()
        }

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
    case encode_checked(seq, payload, timestamp) do
      {:ok, frame} ->
        frame

      {:error, {:frame_too_large, size, maximum}} ->
        raise ArgumentError, "frame payload is #{size} bytes; maximum is #{maximum}"
    end
  end

  @doc false
  @spec encode_checked(pos_integer(), term(), integer()) ::
          {:ok, binary()} | {:error, {:frame_too_large, non_neg_integer(), pos_integer()}}
  def encode_checked(seq, payload, timestamp \\ System.system_time(:millisecond))
      when is_integer(seq) and seq > 0 and is_integer(timestamp) do
    encode_checked(seq, payload, timestamp, [])
  end

  @doc false
  @spec encode_checked(pos_integer(), term(), integer(), keyword()) ::
          {:ok, binary()}
          | {:error, {:frame_too_large, non_neg_integer(), pos_integer()} | :invalid_frame_format}
  def encode_checked(seq, payload, timestamp, opts)
      when is_integer(seq) and seq > 0 and is_integer(timestamp) and is_list(opts) do
    magic = Keyword.get(opts, :magic, @magic)
    version = Keyword.get(opts, :version, @version)
    encoded_payload = :erlang.term_to_binary(payload, [:compressed])
    maximum = max_payload_bytes()

    cond do
      not valid_format?(magic, version) ->
        {:error, :invalid_frame_format}

      safe_payload_size?(encoded_payload, maximum) ->
        crc = :erlang.crc32(encoded_payload)

        {:ok,
         <<magic::binary, version, seq::unsigned-64, timestamp::signed-64,
           byte_size(encoded_payload)::32, crc::32, encoded_payload::binary>>}

      true ->
        {:error, {:frame_too_large, payload_size(encoded_payload), maximum}}
    end
  end

  @doc false
  @spec max_payload_bytes :: pos_integer()
  def max_payload_bytes do
    case Application.get_env(:spectre_mnemonic, :max_frame_bytes, @default_max_payload_bytes) do
      maximum when is_integer(maximum) and maximum > 0 -> maximum
      _invalid -> @default_max_payload_bytes
    end
  end

  @doc """
  Scans a framed log and reports the last validated byte boundary.

  Unlike `read_frames/3`, this function makes an invalid tail observable. A
  writer can therefore truncate exactly the unreachable suffix before it
  appends again. `:magic` and `:version` exist so the knowledge log can share
  the same recovery invariant without changing its on-disk format.
  """
  @spec scan_path(Path.t(), keyword()) :: {:ok, scan_result()} | {:error, term()}
  def scan_path(path, opts \\ []) do
    magic = Keyword.get(opts, :magic, @magic)
    version = Keyword.get(opts, :version, @version)

    with true <- is_binary(magic) and byte_size(magic) == byte_size(@magic),
         true <- is_integer(version) and version in 0..255 do
      case File.open(path, [:read, :binary, :raw]) do
        {:ok, io} ->
          try do
            with {:ok, %{size: file_bytes}} <- File.stat(path) do
              scan_frames(io, 0, 0, file_bytes, magic, version)
            end
          after
            File.close(io)
          end

        {:error, :enoent} ->
          {:ok, %{valid_bytes: 0, file_bytes: 0, last_sequence: 0, status: :clean}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_frame_format}
    end
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
    read_frames(io, acc, fun, [])
  end

  @doc false
  @spec read_frames(File.io_device(), acc, fold_fun(acc), keyword()) :: acc when acc: term()
  def read_frames(io, acc, fun, opts) when is_function(fun, 2) and is_list(opts) do
    # I chose framed append-only storage because the recovery story is boring:
    # read until the bytes stop making sense, then stop. Future work can add
    # better repair tooling; today we do not turn one bad tail into a funeral.
    magic = Keyword.get(opts, :magic, @magic)
    version = Keyword.get(opts, :version, @version)

    case IO.binread(io, @header_bytes) do
      <<^magic::binary-size(4), ^version, seq::unsigned-64, timestamp::signed-64, len::32,
        crc::32>> ->
        read_payload(io, seq, timestamp, len, crc, acc, fun, opts)

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
          fold_fun(acc),
          keyword()
        ) :: acc
        when acc: term()
  defp read_payload(io, seq, timestamp, len, crc, acc, fun, opts) do
    if len <= max_payload_bytes() do
      case IO.binread(io, len) do
        payload when is_binary(payload) and byte_size(payload) == len ->
          read_complete_payload(io, seq, timestamp, payload, crc, acc, fun, opts)

        _incomplete_or_error ->
          acc
      end
    else
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
          fold_fun(acc),
          keyword()
        ) :: acc
        when acc: term()
  defp read_complete_payload(io, seq, timestamp, payload, crc, acc, fun, opts) do
    if :erlang.crc32(payload) == crc do
      case decode_payload(payload) do
        {:ok, decoded} -> continue_frame(io, {seq, timestamp, decoded}, acc, fun, opts)
        :error -> acc
      end
    else
      acc
    end
  end

  @spec decode_payload(binary()) :: {:ok, term()} | :error
  defp decode_payload(payload) do
    if safe_payload_size?(payload, max_payload_bytes()) do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    else
      :error
    end
  rescue
    _exception -> :error
  end

  @spec safe_payload_size?(binary(), pos_integer()) :: boolean()
  defp safe_payload_size?(payload, maximum) do
    payload_size(payload) <= maximum
  end

  @spec payload_size(binary()) :: non_neg_integer()
  defp payload_size(payload), do: max(byte_size(payload), expanded_payload_size(payload))

  @spec expanded_payload_size(binary()) :: non_neg_integer()
  defp expanded_payload_size(<<131, 80, expanded::unsigned-big-32, _compressed::binary>>),
    do: expanded

  defp expanded_payload_size(payload), do: byte_size(payload)

  @spec continue_frame(File.io_device(), t(), acc, fold_fun(acc), keyword()) :: acc
        when acc: term()
  defp continue_frame(io, frame, acc, fun, opts) do
    case fun.(frame, acc) do
      {:cont, acc} -> read_frames(io, acc, fun, opts)
      {:halt, acc} -> acc
    end
  end

  @spec valid_format?(term(), term()) :: boolean()
  defp valid_format?(magic, version),
    do: is_binary(magic) and byte_size(magic) == byte_size(@magic) and version in 0..255

  @spec scan_frames(
          File.io_device(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          binary(),
          non_neg_integer()
        ) :: {:ok, scan_result()} | {:error, term()}
  defp scan_frames(io, offset, last_sequence, file_bytes, magic, version) do
    case :file.read(io, @header_bytes) do
      :eof ->
        {:ok,
         %{
           valid_bytes: offset,
           file_bytes: file_bytes,
           last_sequence: last_sequence,
           status: :clean
         }}

      {:ok, header} when byte_size(header) < @header_bytes ->
        invalid_scan(offset, file_bytes, last_sequence, :incomplete_header)

      {:ok,
       <<^magic::binary, ^version, seq::unsigned-64, _timestamp::signed-64, len::32, crc::32>>} ->
        context = %{
          offset: offset,
          last_sequence: last_sequence,
          file_bytes: file_bytes,
          magic: magic,
          version: version
        }

        scan_payload(io, context, seq, len, crc)

      {:ok, _unknown_header} ->
        invalid_scan(offset, file_bytes, last_sequence, :unknown_header)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec scan_payload(
          File.io_device(),
          map(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, scan_result()} | {:error, term()}
  defp scan_payload(io, context, seq, len, crc) do
    if len <= max_payload_bytes() do
      case :file.read(io, len) do
        {:ok, payload} when byte_size(payload) == len ->
          scan_complete_payload(io, context, seq, payload, crc)

        :eof ->
          invalid_context_scan(context, :incomplete_payload)

        {:ok, _incomplete} ->
          invalid_context_scan(context, :incomplete_payload)

        {:error, reason} ->
          {:error, reason}
      end
    else
      invalid_context_scan(context, :payload_too_large)
    end
  end

  @spec scan_complete_payload(
          File.io_device(),
          map(),
          non_neg_integer(),
          binary(),
          non_neg_integer()
        ) :: {:ok, scan_result()} | {:error, term()}
  defp scan_complete_payload(io, context, seq, payload, crc) do
    if :erlang.crc32(payload) != crc do
      invalid_context_scan(context, :crc_mismatch)
    else
      next_offset = context.offset + @header_bytes + byte_size(payload)

      scan_frames(
        io,
        next_offset,
        max(seq, context.last_sequence),
        context.file_bytes,
        context.magic,
        context.version
      )
    end
  end

  @spec invalid_context_scan(map(), atom()) :: {:ok, scan_result()}
  defp invalid_context_scan(context, reason) do
    invalid_scan(context.offset, context.file_bytes, context.last_sequence, reason)
  end

  @spec invalid_scan(non_neg_integer(), non_neg_integer(), non_neg_integer(), atom()) ::
          {:ok, scan_result()}
  defp invalid_scan(valid_bytes, file_bytes, last_sequence, reason) do
    {:ok,
     %{
       valid_bytes: valid_bytes,
       file_bytes: file_bytes,
       last_sequence: last_sequence,
       status: {:invalid_tail, reason}
     }}
  end
end
