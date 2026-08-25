defmodule SpectreMnemonic.Export.Reader do
  @moduledoc false

  alias SpectreMnemonic.JSON
  alias SpectreMnemonic.Persistence.Store.FileFrame

  @magic "SMNE"
  @version 1
  @header_bytes 4 + 1 + 8 + 4 + 4
  @content_sections ~w(nodes edges clusters models knowledge governance)
  @manifest_fields ~w(format format_version library_version namespace scope scope_digest privacy_mode created_at counts content_digest)
  @record_fields ~w(family id namespace scope_digest inserted_at)
  @forbidden_structure_fields ~w(text input summary statement answer title canonical aliases category categories label vector binary_signature embedding ciphertext iv tag aad)
  @secret_forbidden_fields ~w(text input summary statement answer vector binary_signature embedding ciphertext iv tag aad plaintext)
  @digest_regex ~r/^[0-9a-f]{64}$/

  @spec read(Path.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read(path, opts \\ []) do
    with :ok <- validate_reader_options(path, opts),
         :ok <- JSON.ensure_decoder(),
         :ok <- verify_file(path),
         {:ok, frames} <-
           fold_frames(path, [], fn frame, _json, acc -> {:cont, [frame | acc]} end) do
      {:ok, Enum.reverse(frames)}
    end
  end

  @spec stream(Path.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(path, opts \\ []) do
    with :ok <- validate_reader_options(path, opts),
         :ok <- JSON.ensure_decoder(),
         :ok <- verify_file(path) do
      {:ok, frame_stream(path)}
    end
  end

  @spec validate_reader_options(term(), term()) :: :ok | {:error, term()}
  defp validate_reader_options(path, opts) do
    cond do
      not is_binary(path) or path == "" ->
        {:error, {:invalid_mnemonic_path, path}}

      not is_list(opts) or not Keyword.keyword?(opts) ->
        {:error, {:invalid_mnemonic_options, opts}}

      true ->
        :ok
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

    case fold_frames(path, initial, &verify_frame/3) do
      {:ok, state} -> finalize_verification(state)
      {:error, _reason} = error -> error
    end
  end

  @spec verify_frame(map(), binary(), map()) :: {:cont, map()} | {:halt, map()}
  defp verify_frame(
         %{"section" => "manifest", "data" => manifest},
         _json,
         %{manifest: nil} = state
       )
       when is_map(manifest) and state.last_section == -1 do
    {:cont, %{state | manifest: manifest}}
  end

  defp verify_frame(
         %{"section" => "trailer", "data" => trailer},
         _json,
         %{trailer: nil} = state
       )
       when is_map(trailer) and state.last_section == 5 do
    {:cont, %{state | trailer: trailer}}
  end

  defp verify_frame(%{"section" => section, "data" => data}, json, state)
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
        |> Map.update!(:digest, &:crypto.hash_update(&1, json))
        |> verify_privacy_data(data)
        |> verify_partition_data(data)

      {:cont, state}
    else
      {:halt, Map.put(state, :error, :invalid_mnemonic_sections)}
    end
  end

  defp verify_frame(_frame, _json, state),
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

  @spec verify_privacy_data(map(), [term()]) :: map()
  defp verify_privacy_data(%{error: _reason} = state, _data), do: state

  defp verify_privacy_data(state, data) do
    mode = Map.get(state.manifest, "privacy_mode")

    case Enum.find_value(data, &privacy_violation(&1, mode)) do
      nil -> state
      violation -> Map.put(state, :error, violation)
    end
  end

  @spec privacy_violation(map(), binary()) :: term() | nil
  defp privacy_violation(record, mode) do
    cond do
      secret_record?(record) ->
        forbidden_field(record, @secret_forbidden_fields, record)

      mode == "structure" ->
        forbidden_field(record, @forbidden_structure_fields, record)

      true ->
        nil
    end
  end

  @spec secret_record?(map()) :: boolean()
  defp secret_record?(record) do
    Map.get(record, "secret") == true or Map.get(record, "kind") == "secret" or
      Map.get(record, "family") == "secrets"
  end

  @spec forbidden_field(term(), [binary()], map()) :: term() | nil
  defp forbidden_field(value, forbidden, record) do
    case find_forbidden_field(value, MapSet.new(forbidden)) do
      nil -> nil
      field -> {:mnemonic_privacy_violation, Map.get(record, "id"), field}
    end
  end

  @spec find_forbidden_field(term(), MapSet.t(binary())) :: binary() | nil
  defp find_forbidden_field(value, forbidden) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      key = to_string(key)
      if MapSet.member?(forbidden, key), do: key, else: find_forbidden_field(nested, forbidden)
    end)
  end

  defp find_forbidden_field(value, forbidden) when is_list(value),
    do: Enum.find_value(value, &find_forbidden_field(&1, forbidden))

  defp find_forbidden_field(_value, _forbidden), do: nil

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

  @spec fold_frames(Path.t(), acc, (map(), binary(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp fold_frames(path, acc, fun) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          read_frames(io, 1, acc, fun)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:mnemonic_open_failed, path, reason}}
    end
  end

  @spec read_frames(
          IO.device(),
          pos_integer(),
          acc,
          (map(), binary(), acc -> {:cont, acc} | {:halt, acc})
        ) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp read_frames(io, expected, acc, fun) do
    case decode_next(io, expected) do
      :eof ->
        {:ok, acc}

      {:ok, frame, json} ->
        case fun.(frame, json, acc) do
          {:cont, acc} -> read_frames(io, expected + 1, acc, fun)
          {:halt, %{error: reason}} -> {:error, reason}
          {:halt, acc} -> {:ok, acc}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec decode_next(IO.device(), pos_integer()) ::
          :eof | {:ok, map(), binary()} | {:error, term()}
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
        ) :: {:ok, map(), binary()} | {:error, term()}
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
             {:ok, frame} <- decode_json(json, sequence),
             :ok <- validate_frame(frame, sequence) do
          {:ok, frame, json}
        end
    end
  end

  @spec decode_json(binary(), pos_integer()) :: {:ok, term()} | {:error, term()}
  defp decode_json(json, sequence) do
    case JSON.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, {:invalid_mnemonic_json, sequence}}
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
  defp gunzip(<<0x1F, 0x8B, _rest::binary>> = payload, sequence, maximum) do
    zstream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zstream, 31)
      bounded_inflate(zstream, payload, sequence, maximum, 0, [])
    after
      safe_inflate_end(zstream)
      :zlib.close(zstream)
    end
  rescue
    _exception -> {:error, {:invalid_mnemonic_compression, sequence}}
  catch
    _kind, _reason -> {:error, {:invalid_mnemonic_compression, sequence}}
  end

  defp gunzip(_payload, sequence, _maximum),
    do: {:error, {:invalid_mnemonic_compression, sequence}}

  @spec bounded_inflate(
          :zlib.zstream(),
          iodata(),
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          [iodata()]
        ) :: {:ok, binary()} | {:error, term()}
  defp bounded_inflate(zstream, input, sequence, maximum, expanded, chunks) do
    case :zlib.safeInflate(zstream, input) do
      {status, output} when status in [:continue, :finished] ->
        output_size = IO.iodata_length(output)
        next_size = expanded + output_size

        cond do
          next_size > maximum ->
            {:error, {:mnemonic_expanded_frame_too_large, sequence}}

          status == :finished ->
            {:ok, chunks |> Enum.reverse([output]) |> IO.iodata_to_binary()}

          true ->
            bounded_inflate(zstream, [], sequence, maximum, next_size, [output | chunks])
        end

      {:need_dictionary, _adler, _output} ->
        {:error, {:invalid_mnemonic_compression, sequence}}
    end
  end

  @spec safe_inflate_end(:zlib.zstream()) :: :ok
  defp safe_inflate_end(zstream) do
    :zlib.inflateEnd(zstream)
  rescue
    _exception -> :ok
  end

  @spec validate_frame(term(), pos_integer()) :: :ok | {:error, term()}
  defp validate_frame(%{"section" => section, "data" => data} = frame, sequence)
       when is_binary(section) and map_size(frame) == 2 do
    result =
      case section do
        "manifest" -> validate_manifest_schema(data)
        "trailer" -> validate_trailer_schema(data)
        content when content in @content_sections -> validate_content_schema(content, data)
        _unknown -> :ok
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_mnemonic_schema, sequence, section, reason}}
    end
  end

  defp validate_frame(_frame, sequence), do: {:error, {:invalid_mnemonic_frame, sequence}}

  @spec validate_manifest_schema(term()) :: :ok | {:error, term()}
  defp validate_manifest_schema(manifest) when is_map(manifest) do
    checks = [
      {:required_fields, Enum.all?(@manifest_fields, &Map.has_key?(manifest, &1))},
      {:format, is_binary(Map.get(manifest, "format"))},
      {:format_version, is_integer(Map.get(manifest, "format_version"))},
      {:library_version, nonempty_string?(Map.get(manifest, "library_version"))},
      {:namespace, nonempty_string?(Map.get(manifest, "namespace"))},
      {:scope, is_binary(Map.get(manifest, "scope"))},
      {:scope_digest, valid_digest?(Map.get(manifest, "scope_digest"))},
      {:privacy_mode, Map.get(manifest, "privacy_mode") in ~w(structure full redacted)},
      {:created_at, valid_datetime?(Map.get(manifest, "created_at"))},
      {:counts, valid_counts?(Map.get(manifest, "counts"))},
      {:content_digest, valid_digest?(Map.get(manifest, "content_digest"))}
    ]

    schema_checks(checks)
  end

  defp validate_manifest_schema(_manifest), do: {:error, :manifest_not_an_object}

  @spec validate_trailer_schema(term()) :: :ok | {:error, term()}
  defp validate_trailer_schema(trailer) when is_map(trailer) do
    schema_checks([
      {:required_fields, Enum.all?(~w(counts content_digest), &Map.has_key?(trailer, &1))},
      {:only_known_fields,
       trailer |> Map.keys() |> Enum.sort() == Enum.sort(~w(counts content_digest))},
      {:counts, valid_counts?(Map.get(trailer, "counts"))},
      {:content_digest, valid_digest?(Map.get(trailer, "content_digest"))}
    ])
  end

  defp validate_trailer_schema(_trailer), do: {:error, :trailer_not_an_object}

  @spec validate_content_schema(binary(), term()) :: :ok | {:error, term()}
  defp validate_content_schema(section, data) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {record, index}, :ok ->
      case validate_record_schema(section, record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:record, index, reason}}}
      end
    end)
  end

  defp validate_content_schema(_section, _data), do: {:error, :content_not_an_array}

  @spec validate_record_schema(binary(), term()) :: :ok | {:error, term()}
  defp validate_record_schema(section, record) when is_map(record) do
    envelope = [
      {:required_fields, Enum.all?(@record_fields, &Map.has_key?(record, &1))},
      {:family, nonempty_string?(Map.get(record, "family"))},
      {:id, nonempty_string?(Map.get(record, "id"))},
      {:namespace, nonempty_string?(Map.get(record, "namespace"))},
      {:scope_digest, valid_digest?(Map.get(record, "scope_digest"))},
      {:inserted_at, valid_optional_datetime?(Map.get(record, "inserted_at"))}
    ]

    with :ok <- schema_checks(envelope) do
      validate_section_record(section, record)
    end
  end

  defp validate_record_schema(_section, _record), do: {:error, :record_not_an_object}

  @spec validate_section_record(binary(), map()) :: :ok | {:error, term()}
  defp validate_section_record("edges", record) do
    weight = Map.get(record, "weight")

    schema_checks([
      {:source_id, nonempty_string?(Map.get(record, "source_id"))},
      {:target_id, nonempty_string?(Map.get(record, "target_id"))},
      {:relation, nonempty_string?(Map.get(record, "relation"))},
      {:weight, is_number(weight) and weight >= 0 and weight <= 1}
    ])
  end

  defp validate_section_record("clusters", record) do
    moment_ids = Map.get(record, "moment_ids")
    title = Map.get(record, "title")

    schema_checks([
      {:title, not Map.has_key?(record, "title") or nonempty_string?(title)},
      {:moment_ids, is_list(moment_ids) and Enum.all?(moment_ids, &nonempty_string?/1)}
    ])
  end

  defp validate_section_record(_section, _record), do: :ok

  @spec schema_checks([{term(), boolean()}]) :: :ok | {:error, term()}
  defp schema_checks(checks) do
    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, false} -> {:error, field}
    end
  end

  @spec valid_counts?(term()) :: boolean()
  defp valid_counts?(counts) when is_map(counts) do
    Map.keys(counts) |> Enum.sort() == Enum.sort(@content_sections) and
      Enum.all?(@content_sections, fn section ->
        value = Map.get(counts, section)
        is_integer(value) and value >= 0
      end)
  end

  defp valid_counts?(_counts), do: false

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest), do: Regex.match?(@digest_regex, digest)
  defp valid_digest?(_digest), do: false

  @spec valid_datetime?(term()) :: boolean()
  defp valid_datetime?(value) when is_binary(value) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_datetime?(_value), do: false

  @spec valid_optional_datetime?(term()) :: boolean()
  defp valid_optional_datetime?(nil), do: true
  defp valid_optional_datetime?(value), do: valid_datetime?(value)

  @spec nonempty_string?(term()) :: boolean()
  defp nonempty_string?(value), do: is_binary(value) and value != ""

  @spec frame_stream(Path.t()) :: Enumerable.t()
  defp frame_stream(path) do
    Stream.resource(
      fn ->
        case File.open(path, [:read, :binary]) do
          {:ok, io} -> {:open, io, 1}
          {:error, reason} -> {:error, {:mnemonic_open_failed, path, reason}}
        end
      end,
      fn
        {:open, io, expected} = state ->
          case decode_next(io, expected) do
            :eof -> {:halt, state}
            {:ok, frame, _json} -> {[frame], {:open, io, expected + 1}}
            {:error, reason} -> {[{:error, reason}], {:halted, io}}
          end

        {:error, reason} ->
          {[{:error, reason}], :halted}

        {:halted, _io} = state ->
          {:halt, state}

        :halted ->
          {:halt, :halted}
      end,
      fn
        {:open, io, _expected} -> File.close(io)
        {:halted, io} -> File.close(io)
        _state -> :ok
      end
    )
  end
end
