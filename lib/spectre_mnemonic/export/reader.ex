defmodule SpectreMnemonic.Export.Reader do
  @moduledoc false

  alias SpectreMnemonic.Export.CanonicalJSON
  alias SpectreMnemonic.Persistence.Store.FileFrame

  @magic "SMNE"
  @version 1
  @header_bytes 4 + 1 + 8 + 4 + 4
  @content_sections ~w(nodes edges clusters models knowledge governance)

  @spec read(Path.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read(path, _opts \\ []) do
    with :ok <- verify_file(path),
         {:ok, frames} <- fold_frames(path, [], fn frame, acc -> {:cont, [frame | acc]} end) do
      {:ok, Enum.reverse(frames)}
    end
  end

  @spec stream(Path.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(path, _opts \\ []) do
    with :ok <- verify_file(path) do
      {:ok, frame_stream(path)}
    end
  end

  @spec verify_file(Path.t()) :: :ok | {:error, term()}
  defp verify_file(path) do
    initial = %{
      manifest: nil,
      trailer: nil,
      last_section: -1,
      counts: %{},
      digest: :crypto.hash_init(:sha256)
    }

    case fold_frames(path, initial, &verify_frame/2) do
      {:ok, state} -> finalize_verification(state)
      {:error, _reason} = error -> error
    end
  end

  @spec verify_frame(map(), map()) :: {:cont, map()} | {:halt, map()}
  defp verify_frame(%{"section" => "manifest", "data" => manifest}, %{manifest: nil} = state)
       when is_map(manifest) and state.last_section == -1 do
    {:cont, %{state | manifest: manifest}}
  end

  defp verify_frame(
         %{"section" => "trailer", "data" => trailer},
         %{trailer: nil} = state
       )
       when is_map(trailer) and state.last_section == 5 do
    {:cont, %{state | trailer: trailer}}
  end

  defp verify_frame(%{"section" => section, "data" => data} = frame, state)
       when section in @content_sections and is_list(data) do
    index = Enum.find_index(@content_sections, &(&1 == section))

    if not is_nil(state.manifest) and is_nil(state.trailer) and
         index in [state.last_section, state.last_section + 1] do
      state =
        state
        |> Map.put(:last_section, index)
        |> Map.update!(
          :counts,
          &Map.update(&1, section, length(data), fn count ->
            count + length(data)
          end)
        )
        |> Map.update!(:digest, &:crypto.hash_update(&1, CanonicalJSON.encode(frame)))
        |> verify_partition_data(data)

      {:cont, state}
    else
      {:halt, Map.put(state, :error, :invalid_mnemonic_sections)}
    end
  end

  defp verify_frame(_frame, state),
    do: {:halt, Map.put(state, :error, :invalid_mnemonic_sections)}

  @spec verify_partition_data(map(), [term()]) :: map()
  defp verify_partition_data(%{error: _reason} = state, _data), do: state

  defp verify_partition_data(state, data) do
    namespace = Map.get(state.manifest, "namespace")
    scope_digest = Map.get(state.manifest, "scope_digest")

    case Enum.find(data, fn record ->
           not is_map(record) or Map.get(record, "namespace") != namespace or
             Map.get(record, "scope_digest") != scope_digest
         end) do
      nil -> state
      invalid -> Map.put(state, :error, {:mixed_mnemonic_partition, invalid})
    end
  end

  @spec finalize_verification(map()) :: :ok | {:error, term()}
  defp finalize_verification(%{error: reason}), do: {:error, reason}

  defp finalize_verification(%{
         manifest: manifest,
         trailer: trailer,
         last_section: 5,
         counts: counts,
         digest: digest_context
       })
       when is_map(manifest) and is_map(trailer) do
    counts = Map.new(@content_sections, &{&1, Map.get(counts, &1, 0)})

    digest =
      digest_context
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    [
      verify_version(manifest),
      verify_digest(digest, manifest, trailer),
      verify_counts(counts, manifest, trailer)
    ]
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  defp finalize_verification(_state), do: {:error, :invalid_mnemonic_sections}

  @spec verify_version(map()) :: :ok | {:error, term()}
  defp verify_version(%{"format" => "spectre-mnemonic", "format_version" => @version}), do: :ok
  defp verify_version(manifest), do: {:error, {:unsupported_mnemonic_format, manifest}}

  @spec verify_digest(binary(), map(), map()) :: :ok | {:error, term()}
  defp verify_digest(digest, manifest, trailer) do
    if digest == Map.get(manifest, "content_digest") and
         digest == Map.get(trailer, "content_digest"),
       do: :ok,
       else: {:error, :mnemonic_digest_mismatch}
  end

  @spec verify_counts(map(), map(), map()) :: :ok | {:error, term()}
  defp verify_counts(actual, manifest, trailer) do
    manifest_counts = Map.get(manifest, "counts")
    trailer_counts = Map.get(trailer, "counts")

    if actual == manifest_counts and actual == trailer_counts,
      do: :ok,
      else: {:error, {:mnemonic_count_mismatch, actual, manifest_counts, trailer_counts}}
  end

  @spec fold_frames(Path.t(), acc, (map(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp fold_frames(path, acc, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          read_frames(io, 1, acc, fun)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_frames(IO.device(), pos_integer(), acc, (map(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp read_frames(io, expected, acc, fun) do
    case decode_next(io, expected) do
      :eof ->
        {:ok, acc}

      {:ok, frame} ->
        case fun.(frame, acc) do
          {:cont, acc} -> read_frames(io, expected + 1, acc, fun)
          {:halt, %{error: reason}} -> {:error, reason}
          {:halt, acc} -> {:ok, acc}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec decode_next(IO.device(), pos_integer()) :: :eof | {:ok, map()} | {:error, term()}
  defp decode_next(io, expected) do
    case IO.binread(io, @header_bytes) do
      :eof ->
        :eof

      {:error, reason} ->
        {:error, reason}

      header when byte_size(header) < @header_bytes ->
        {:error, {:truncated_mnemonic_header, expected}}

      <<@magic, @version, sequence::unsigned-64, length::unsigned-32, crc::unsigned-32>> ->
        decode_payload(io, expected, sequence, length, crc)

      <<magic::binary-size(4), version, _rest::binary>> ->
        {:error, {:invalid_mnemonic_header, expected, magic, version}}
    end
  end

  @spec decode_payload(
          IO.device(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, map()} | {:error, term()}
  defp decode_payload(io, expected, sequence, length, crc) do
    maximum = FileFrame.max_payload_bytes()

    cond do
      sequence != expected ->
        {:error, {:invalid_mnemonic_sequence, expected, sequence}}

      length > maximum ->
        {:error, {:mnemonic_frame_too_large, sequence, length}}

      true ->
        with {:ok, payload} <- read_payload(io, length, sequence),
             :ok <- verify_crc(payload, crc, sequence),
             {:ok, json} <- gunzip(payload, sequence, maximum),
             {:ok, frame} <- Jason.decode(json),
             :ok <- validate_frame(frame, sequence) do
          {:ok, frame}
        end
    end
  end

  @spec read_payload(IO.device(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp read_payload(_io, 0, _sequence), do: {:ok, <<>>}

  defp read_payload(io, length, sequence) do
    case IO.binread(io, length) do
      payload when is_binary(payload) and byte_size(payload) == length ->
        {:ok, payload}

      _eof_or_short ->
        {:error, {:truncated_mnemonic_frame, sequence}}
    end
  end

  @spec verify_crc(binary(), non_neg_integer(), pos_integer()) :: :ok | {:error, term()}
  defp verify_crc(payload, expected, sequence) do
    if :erlang.crc32(payload) == expected,
      do: :ok,
      else: {:error, {:mnemonic_crc_mismatch, sequence}}
  end

  @spec gunzip(binary(), pos_integer(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  defp gunzip(payload, sequence, maximum) do
    decoded = :zlib.gunzip(payload)

    if byte_size(decoded) <= maximum,
      do: {:ok, decoded},
      else: {:error, {:mnemonic_expanded_frame_too_large, sequence}}
  rescue
    _exception -> {:error, {:invalid_mnemonic_compression, sequence}}
  end

  @spec validate_frame(term(), pos_integer()) :: :ok | {:error, term()}
  defp validate_frame(%{"section" => section, "data" => _data}, _sequence)
       when is_binary(section),
       do: :ok

  defp validate_frame(_frame, sequence), do: {:error, {:invalid_mnemonic_frame, sequence}}

  @spec frame_stream(Path.t()) :: Enumerable.t()
  defp frame_stream(path) do
    Stream.resource(
      fn ->
        case File.open(path, [:read, :binary]) do
          {:ok, io} -> {io, 1}
          {:error, reason} -> raise File.Error, reason: reason, action: "open", path: path
        end
      end,
      fn {io, expected} = state ->
        case decode_next(io, expected) do
          :eof -> {:halt, state}
          {:ok, frame} -> {[frame], {io, expected + 1}}
          {:error, reason} -> raise ArgumentError, "invalid .mnemonic stream: #{inspect(reason)}"
        end
      end,
      fn {io, _expected} -> File.close(io) end
    )
  end
end
