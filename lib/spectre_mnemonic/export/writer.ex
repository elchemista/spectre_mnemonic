defmodule SpectreMnemonic.Export.Writer do
  @moduledoc false

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Atlas
  alias SpectreMnemonic.Export.CanonicalJSON
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Knowledge.SMEM
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.Store.Record

  @magic "SMNE"
  @version 1
  @all_sections [:nodes, :edges, :clusters, :models, :knowledge, :governance]

  @spec write(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(path, opts) do
    with :ok <- validate_write_options(path, opts),
         {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, sections, snapshot_at} <- sections(opts),
         {:ok, frames} <- content_frames(sections, opts),
         digest <- content_digest(frames),
         manifest <- manifest(sections, snapshot_at, digest, opts),
         trailer <- trailer(sections, digest),
         all_frames <-
           [%{section: "manifest", data: manifest} | frames] ++
             [%{section: "trailer", data: trailer}],
         {:ok, bytes} <- install_frames(path, all_frames) do
      {:ok,
       %{
         path: path,
         content_digest: digest,
         counts: trailer["counts"],
         bytes: bytes,
         mode: privacy_mode(opts)
       }}
    end
  end

  @spec validate_write_options(term(), term()) :: :ok | {:error, term()}
  defp validate_write_options(path, opts) do
    with :ok <- validate_export_path(path),
         :ok <- validate_export_options(opts),
         :ok <- validate_export_value(opts, :mode, :structure, &valid_privacy_mode?/1),
         :ok <- validate_export_value(opts, :include, :all, &valid_include?/1),
         :ok <- validate_optional_export_value(opts, :embeddings?, &is_boolean/1),
         :ok <- validate_optional_export_value(opts, :active?, &is_boolean/1) do
      validate_export_value(opts, :frame_target_bytes, nil, &valid_frame_target?/1)
    end
  end

  @spec validate_export_path(term()) :: :ok | {:error, term()}
  defp validate_export_path(path) when is_binary(path) and path != "", do: :ok
  defp validate_export_path(path), do: {:error, {:invalid_export_path, path}}

  @spec validate_export_options(term()) :: :ok | {:error, term()}
  defp validate_export_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, {:invalid_export_options, opts}}
  end

  defp validate_export_options(opts), do: {:error, {:invalid_export_options, opts}}

  @spec validate_export_value(keyword(), atom(), term(), (term() -> boolean())) ::
          :ok | {:error, term()}
  defp validate_export_value(opts, key, default, validator) do
    value = Keyword.get(opts, key, default)

    if validator.(value),
      do: :ok,
      else: {:error, {:invalid_export_option, key, value}}
  end

  @spec validate_optional_export_value(keyword(), atom(), (term() -> boolean())) ::
          :ok | {:error, term()}
  defp validate_optional_export_value(opts, key, validator) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if validator.(value),
          do: :ok,
          else: {:error, {:invalid_export_option, key, value}}

      :error ->
        :ok
    end
  end

  @spec valid_privacy_mode?(term()) :: boolean()
  defp valid_privacy_mode?(mode) when mode in [:structure, :full], do: true
  defp valid_privacy_mode?({:redacted, fun}), do: is_function(fun, 1)
  defp valid_privacy_mode?(_mode), do: false

  @spec valid_include?(term()) :: boolean()
  defp valid_include?(:all), do: true

  defp valid_include?(sections) when is_list(sections) do
    Enum.all?(sections, &(&1 in @all_sections))
  end

  defp valid_include?(_sections), do: false

  @spec valid_frame_target?(term()) :: boolean()
  defp valid_frame_target?(nil), do: true
  defp valid_frame_target?(value), do: is_integer(value) and value >= 256

  @spec sections(keyword()) :: {:ok, map(), DateTime.t()} | {:error, term()}
  defp sections(opts) do
    with {:ok, durable} <-
           Manager.replay_fold(opts, %{}, fn %Record{} = record, grouped ->
             {:cont, Map.update(grouped, record.family, [record], &[record | &1])}
           end),
         {:ok, knowledge_events} <- SMEM.replay(opts),
         {:ok, atlas} <- Atlas.build(opts) do
      included = included_sections(opts)
      active? = Keyword.get(opts, :active?, true)

      nodes =
        durable
        |> values([:signals, :moments, :artifacts])
        |> merge_active(active?, :moments, Focus.moments(opts))
        |> project_records(opts)

      edges =
        durable
        |> values([:associations])
        |> merge_active(active?, :associations, atlas.edges)
        |> project_records(opts)

      clusters =
        durable
        |> cluster_values(atlas.clusters, active?)
        |> project_records(opts)

      models = durable |> values([:observations, :mental_models]) |> project_records(opts)

      knowledge =
        (values(durable, [:knowledge]) ++
           Enum.map(knowledge_events, &record_value(:knowledge_events, &1)))
        |> project_records(opts)

      governance = durable |> values([:memory_states]) |> project_records(opts)

      all = %{
        nodes: nodes,
        edges: edges,
        clusters: clusters,
        models: models,
        knowledge: knowledge,
        governance: governance
      }

      sections =
        Map.new(@all_sections, fn section ->
          {section, section_values(section, included, all)}
        end)

      {:ok, sections, snapshot_at(sections)}
    end
  end

  @spec cluster_values(map(), [term()], boolean()) :: list()
  defp cluster_values(durable, _active_clusters, false), do: values(durable, [:episodes])

  defp cluster_values(_durable, active_clusters, true) do
    Enum.map(active_clusters, &record_value(:episodes, &1))
  end

  @spec section_values(atom(), [atom()], map()) :: [map()]
  defp section_values(section, included, all) do
    if section in included,
      do: all |> Map.fetch!(section) |> stable_sort(),
      else: []
  end

  @spec values(map(), [atom()]) :: [{atom(), term(), DateTime.t() | nil}]
  defp values(grouped, families) do
    Enum.flat_map(families, fn family ->
      grouped
      |> Map.get(family, [])
      |> Enum.map(fn %Record{} = record -> {family, record.payload, record.inserted_at} end)
    end)
  end

  @spec merge_active(list(), boolean(), atom(), list()) :: list()
  defp merge_active(records, false, _family, _active), do: records

  defp merge_active(records, true, family, active) do
    (records ++ Enum.map(active, &record_value(family, &1)))
    |> Enum.reduce(%{}, fn {record_family, value, inserted_at}, acc ->
      Map.put(acc, {record_family, item_id(value)}, {record_family, value, inserted_at})
    end)
    |> Map.values()
  end

  @spec record_value(atom(), term()) :: {atom(), term(), DateTime.t() | nil}
  defp record_value(family, value), do: {family, value, inserted_at(value)}

  @spec project_records(list(), keyword()) :: [map()]
  defp project_records(records, opts) do
    Enum.map(records, fn {family, payload, timestamp} ->
      project(family, payload, timestamp, opts)
    end)
  end

  @spec project(atom(), term(), DateTime.t() | nil, keyword()) :: map()
  defp project(family, payload, timestamp, opts) do
    base = projection_base(family, payload, timestamp, opts)

    cond do
      secret?(payload) -> Map.merge(base, secret_projection(payload))
      privacy_mode(opts) == :structure -> Map.merge(base, structure_projection(payload))
      match?({:redacted, _fun}, privacy_mode(opts)) -> redacted_projection(base, payload, opts)
      true -> Map.merge(base, full_projection(payload, opts))
    end
    |> json_safe()
  end

  @spec projection_base(atom(), term(), DateTime.t() | nil, keyword()) :: map()
  defp projection_base(family, payload, timestamp, opts) do
    %{
      "family" => Atom.to_string(family),
      "id" => item_id(payload),
      "namespace" => Identity.namespace!(opts),
      "scope_digest" => scope_digest(opts),
      "inserted_at" => iso8601(inserted_at(payload) || timestamp)
    }
  end

  @spec structure_projection(term()) :: map()
  defp structure_projection(payload) when is_map(payload) do
    metadata = Map.get(payload, :metadata, Map.get(payload, "metadata", %{}))

    %{
      "kind" => value(payload, :kind),
      "relation" => value(payload, :relation),
      "source_id" => value(payload, :source_id),
      "target_id" => value(payload, :target_id),
      "weight" => value(payload, :weight),
      "moment_ids" => value(payload, :moment_ids),
      "title" => if(episode?(payload), do: value(payload, :title), else: nil),
      "state" => value(payload, :state),
      "occurred_at" => value(payload, :occurred_at),
      "observed_at" => value(payload, :observed_at),
      "valid_from" => value(payload, :valid_from),
      "valid_until" => value(payload, :valid_until),
      "metadata" => structural_metadata(metadata)
    }
    |> compact_map()
  end

  defp structure_projection(_payload), do: %{}

  @spec structural_metadata(term()) :: map()
  defp structural_metadata(metadata) when is_map(metadata) do
    keys = [
      :canonical,
      :aliases,
      :entity_type,
      :categories,
      :category,
      :algorithm,
      :deterministic?,
      :size,
      :episode_id,
      :intake_role,
      :extraction_role
    ]

    Map.new(keys, fn key -> {Atom.to_string(key), value(metadata, key)} end)
    |> compact_map()
  end

  defp structural_metadata(_metadata), do: %{}

  @spec full_projection(term(), keyword()) :: map()
  defp full_projection(payload, opts) when is_map(payload) do
    payload
    |> struct_to_map()
    |> Map.drop([:namespace, :scope, "namespace", "scope"])
    |> maybe_drop_embeddings(opts)
    |> stringify_keys()
  end

  defp full_projection(payload, _opts), do: %{"value" => inspect(payload)}

  @spec redacted_projection(map(), term(), keyword()) :: map()
  defp redacted_projection(base, payload, opts) do
    {:redacted, fun} = privacy_mode(opts)

    case fun.(payload) do
      redacted when is_map(redacted) -> Map.merge(base, stringify_keys(redacted))
      redacted -> Map.put(base, "value", redacted)
    end
  rescue
    exception -> Map.put(base, "redaction_error", Exception.message(exception))
  end

  @spec secret_projection(term()) :: map()
  defp secret_projection(payload) do
    %{
      "secret" => true,
      "present" => true,
      "label" => value(payload, :label) || secret_label_from_metadata(payload),
      "locked" => true,
      "occurred_at" => value(payload, :occurred_at),
      "observed_at" => value(payload, :observed_at),
      "valid_from" => value(payload, :valid_from),
      "valid_until" => value(payload, :valid_until)
    }
    |> compact_map()
  end

  @spec secret?(term()) :: boolean()
  defp secret?(%Secret{}), do: true

  defp secret?(payload) when is_map(payload) do
    value(payload, :kind) == :secret or value(payload, :secret?) == true or
      case value(payload, :metadata) do
        metadata when is_map(metadata) -> value(metadata, :secret?) == true
        _metadata -> false
      end
  end

  defp secret?(_payload), do: false

  @spec secret_label_from_metadata(term()) :: term()
  defp secret_label_from_metadata(payload) do
    case value(payload, :metadata) do
      metadata when is_map(metadata) -> value(metadata, :label)
      _metadata -> nil
    end
  end

  @spec content_frames(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp content_frames(sections, opts) do
    target = frame_target_bytes(opts)

    @all_sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, frames} ->
      name = Atom.to_string(section)

      case chunk_section(name, Map.fetch!(sections, section), target) do
        {:ok, chunks} -> {:cont, {:ok, frames ++ chunks}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec chunk_section(binary(), [map()], pos_integer()) :: {:ok, [map()]} | {:error, term()}
  defp chunk_section(section, [], _target), do: {:ok, [%{section: section, data: []}]}

  defp chunk_section(section, records, target) do
    empty_bytes = byte_size(CanonicalJSON.encode(%{section: section, data: []}))

    records
    |> Enum.reduce_while({:ok, [], [], empty_bytes}, fn record, {:ok, chunks, current, bytes} ->
      record_bytes = byte_size(CanonicalJSON.encode(record))
      separator_bytes = if current == [], do: 0, else: 1

      cond do
        empty_bytes + record_bytes > target ->
          {:halt, {:error, {:mnemonic_record_too_large, section, Map.get(record, "id")}}}

        bytes + separator_bytes + record_bytes <= target ->
          {:cont, {:ok, chunks, [record | current], bytes + separator_bytes + record_bytes}}

        true ->
          frame = %{section: section, data: Enum.reverse(current)}
          {:cont, {:ok, [frame | chunks], [record], empty_bytes + record_bytes}}
      end
    end)
    |> case do
      {:ok, chunks, current, _bytes} ->
        {:ok, Enum.reverse([%{section: section, data: Enum.reverse(current)} | chunks])}

      {:error, _reason} = error ->
        error
    end
  end

  @spec frame_target_bytes(keyword()) :: pos_integer()
  defp frame_target_bytes(opts) do
    maximum = FileFrame.max_payload_bytes()

    case Keyword.get(opts, :frame_target_bytes, maximum) do
      value when is_integer(value) and value >= 256 -> min(value, maximum)
      _invalid -> maximum
    end
  end

  @spec content_digest([map()]) :: binary()
  defp content_digest(frames) do
    frames
    |> Enum.map_join("", &CanonicalJSON.encode/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec manifest(map(), DateTime.t(), binary(), keyword()) :: map()
  defp manifest(sections, snapshot_at, digest, opts) do
    %{
      "format" => "spectre-mnemonic",
      "format_version" => @version,
      "library_version" => library_version(),
      "namespace" => Identity.namespace!(opts),
      "scope" => inspect(Keyword.get(opts, :scope), limit: :infinity),
      "scope_digest" => scope_digest(opts),
      "privacy_mode" => privacy_name(opts),
      "created_at" => DateTime.to_iso8601(snapshot_at),
      "content_digest" => digest,
      "counts" => counts(sections)
    }
  end

  @spec library_version :: binary()
  defp library_version do
    case Application.spec(:spectre_mnemonic, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  @spec trailer(map(), binary()) :: map()
  defp trailer(sections, digest) do
    %{"content_digest" => digest, "counts" => counts(sections)}
  end

  @spec counts(map()) :: map()
  defp counts(sections) do
    Map.new(@all_sections, fn section ->
      {Atom.to_string(section), length(Map.fetch!(sections, section))}
    end)
  end

  @spec snapshot_at(map()) :: DateTime.t()
  defp snapshot_at(sections) do
    sections
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&Map.get(&1, "inserted_at"))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn timestamp ->
      case DateTime.from_iso8601(timestamp) do
        {:ok, datetime, _offset} -> [datetime]
        _invalid -> []
      end
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> ~U[1970-01-01 00:00:00Z] end)
  end

  @spec encode_frame(map(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  defp encode_frame(frame, sequence) do
    json = CanonicalJSON.encode(frame)
    compressed = :zlib.gzip(json)
    maximum = FileFrame.max_payload_bytes()

    if byte_size(json) <= maximum and byte_size(compressed) <= maximum do
      crc = :erlang.crc32(compressed)

      {:ok,
       <<@magic, @version, sequence::unsigned-64, byte_size(compressed)::unsigned-32,
         crc::unsigned-32, compressed::binary>>}
    else
      {:error, {:mnemonic_frame_too_large, sequence}}
    end
  rescue
    exception -> {:error, {:mnemonic_encode_failed, Exception.message(exception)}}
  end

  @spec install_frames(Path.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  defp install_frames(path, frames) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(directory),
         {:ok, bytes} <- write_frames(temporary, frames),
         :ok <- File.rename(temporary, path) do
      {:ok, bytes}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  @spec write_frames(Path.t(), [map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  defp write_frames(path, frames) do
    case File.open(path, [:write, :binary], fn io -> write_frame_stream(io, frames) end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  @spec write_frame_stream(IO.device(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp write_frame_stream(io, frames) do
    frames
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, 0}, fn {frame, sequence}, {:ok, bytes} ->
      with {:ok, encoded} <- encode_frame(frame, sequence),
           :ok <- IO.binwrite(io, encoded) do
        {:cont, {:ok, bytes + byte_size(encoded)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bytes} ->
        case :file.sync(io) do
          :ok -> {:ok, bytes}
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec included_sections(keyword()) :: [atom()]
  defp included_sections(opts) do
    case Keyword.get(opts, :include, @all_sections) do
      :all -> @all_sections
      sections when is_list(sections) -> Enum.filter(@all_sections, &(&1 in sections))
      _invalid -> @all_sections
    end
  end

  @spec privacy_mode(keyword()) :: :structure | :full | {:redacted, function()}
  defp privacy_mode(opts) do
    case Keyword.get(opts, :mode, :structure) do
      :full -> :full
      {:redacted, fun} when is_function(fun, 1) -> {:redacted, fun}
      _structure -> :structure
    end
  end

  @spec privacy_name(keyword()) :: binary()
  defp privacy_name(opts) do
    case privacy_mode(opts) do
      :structure -> "structure"
      :full -> "full"
      {:redacted, _fun} -> "redacted"
    end
  end

  @spec stable_sort([map()]) :: [map()]
  defp stable_sort(records) do
    Enum.sort_by(records, fn record ->
      {Map.get(record, "family", ""), Map.get(record, "inserted_at", ""),
       Map.get(record, "id", "")}
    end)
  end

  @spec scope_digest(keyword()) :: binary()
  defp scope_digest(opts) do
    {Identity.namespace!(opts), Keyword.get(opts, :scope)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec item_id(term()) :: binary()
  defp item_id(payload) when is_map(payload) do
    case value(payload, :id) do
      id when is_binary(id) -> id
      nil -> "anonymous_" <> binary_part(digest(payload), 0, 24)
      id when is_atom(id) -> Atom.to_string(id)
      id -> to_string(id)
    end
  end

  defp item_id(payload), do: "anonymous_" <> binary_part(digest(payload), 0, 24)

  @spec digest(term()) :: binary()
  defp digest(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec inserted_at(term()) :: DateTime.t() | nil
  defp inserted_at(payload) when is_map(payload) do
    case value(payload, :inserted_at) do
      %DateTime{} = datetime -> datetime
      _missing -> nil
    end
  end

  defp inserted_at(_payload), do: nil

  @spec iso8601(term()) :: binary() | nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value) when is_binary(value), do: value
  defp iso8601(_value), do: nil

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @spec episode?(map()) :: boolean()
  defp episode?(%{__struct__: module}), do: module == SpectreMnemonic.Memory.Episode

  defp episode?(payload),
    do: not is_nil(value(payload, :moment_ids)) and not is_nil(value(payload, :title))

  @spec compact_map(map()) :: map()
  defp compact_map(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  @spec struct_to_map(map()) :: map()
  defp struct_to_map(%{__struct__: _module} = value), do: Map.from_struct(value)
  defp struct_to_map(value), do: value

  @spec maybe_drop_embeddings(map(), keyword()) :: map()
  defp maybe_drop_embeddings(payload, opts) do
    if Keyword.get(opts, :embeddings?, false) do
      payload
    else
      Map.drop(payload, [
        :vector,
        :binary_signature,
        :embedding,
        "vector",
        "binary_signature",
        "embedding"
      ])
    end
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  @spec json_safe(term()) :: term()
  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp json_safe(%Date{} = date), do: Date.to_iso8601(date)
  defp json_safe(%Time{} = time), do: Time.to_iso8601(time)
  defp json_safe(struct) when is_struct(struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(nil), do: nil
  defp json_safe(true), do: true
  defp json_safe(false), do: false
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$binary" => Base.encode64(value)}
  end

  defp json_safe(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp json_safe(value), do: inspect(value, limit: :infinity)
end
