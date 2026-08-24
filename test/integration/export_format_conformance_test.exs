defmodule SpectreMnemonic.JSONSchemaTestValidator do
  @moduledoc false

  def valid?(schema, value), do: validate(schema, value, schema)

  defp validate(%{"$ref" => reference}, value, root),
    do: root |> resolve(reference) |> validate(value, root)

  defp validate(%{"oneOf" => schemas}, value, root),
    do: Enum.count(schemas, &validate(&1, value, root)) == 1

  defp validate(%{"allOf" => schemas}, value, root),
    do: Enum.all?(schemas, &validate(&1, value, root))

  defp validate(schema, value, root) do
    valid_type?(Map.get(schema, "type"), value) and
      valid_const?(Map.fetch(schema, "const"), value) and
      valid_enum?(Map.get(schema, "enum"), value) and
      valid_object?(schema, value, root) and
      valid_array?(schema, value, root) and
      valid_string?(schema, value) and
      valid_number?(schema, value)
  end

  defp resolve(root, "#/" <> pointer) do
    pointer
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce(root, &Map.fetch!(&2, &1))
  end

  defp valid_type?(nil, _value), do: true

  defp valid_type?(types, value) when is_list(types),
    do: Enum.any?(types, &valid_type?(&1, value))

  defp valid_type?("object", value), do: is_map(value)
  defp valid_type?("array", value), do: is_list(value)
  defp valid_type?("string", value), do: is_binary(value)
  defp valid_type?("integer", value), do: is_integer(value)
  defp valid_type?("number", value), do: is_number(value)
  defp valid_type?("boolean", value), do: is_boolean(value)
  defp valid_type?("null", value), do: is_nil(value)
  defp valid_type?(_unknown, _value), do: false

  defp valid_const?(:error, _value), do: true
  defp valid_const?({:ok, expected}, value), do: value == expected

  defp valid_enum?(nil, _value), do: true
  defp valid_enum?(values, value), do: value in values

  defp valid_object?(schema, value, root) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    Enum.all?(required, &Map.has_key?(value, &1)) and
      Enum.all?(properties, fn {key, property_schema} ->
        not Map.has_key?(value, key) or validate(property_schema, Map.get(value, key), root)
      end) and
      (Map.get(schema, "additionalProperties", true) != false or
         Enum.all?(Map.keys(value), &Map.has_key?(properties, &1)))
  end

  defp valid_object?(_schema, _value, _root), do: true

  defp valid_array?(%{"items" => item_schema}, value, root) when is_list(value),
    do: Enum.all?(value, &validate(item_schema, &1, root))

  defp valid_array?(_schema, _value, _root), do: true

  defp valid_string?(schema, value) when is_binary(value) do
    minimum = Map.get(schema, "minLength", 0)
    pattern = Map.get(schema, "pattern")
    format = Map.get(schema, "format")

    String.length(value) >= minimum and
      (is_nil(pattern) or Regex.match?(Regex.compile!(pattern), value)) and
      valid_format?(format, value)
  end

  defp valid_string?(_schema, _value), do: true

  defp valid_format?(nil, _value), do: true

  defp valid_format?("date-time", value),
    do: match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(value))

  defp valid_format?(_unknown, _value), do: true

  defp valid_number?(schema, value) when is_number(value) do
    value >= Map.get(schema, "minimum", value) and value <= Map.get(schema, "maximum", value)
  end

  defp valid_number?(_schema, _value), do: true
end

defmodule SpectreMnemonic.ExportFormatConformanceTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Export.CanonicalJSON
  alias SpectreMnemonic.Export.Reader
  alias SpectreMnemonic.Persistence.Store.FileFrame

  @namespace "spectre_mnemonic_test"
  @scope_digest String.duplicate("a", 64)
  @sections ~w(nodes edges clusters models knowledge governance)

  test "writer rejects malformed paths and option containers" do
    assert {:error, {:invalid_export_path, nil}} = SpectreMnemonic.export(nil)
    assert {:error, {:invalid_export_path, ""}} = SpectreMnemonic.export("")

    assert {:error, {:invalid_export_options, %{mode: :full}}} =
             SpectreMnemonic.export(path("bad-options"), %{mode: :full})

    assert {:error, {:invalid_export_options, [:not_a_keyword]}} =
             SpectreMnemonic.export(path("bad-list"), [:not_a_keyword])
  end

  test "writer validates every bounded export option" do
    invalid = [
      {:mode, :private},
      {:mode, {:redacted, :not_a_function}},
      {:include, :nodes},
      {:include, [:nodes, :unknown]},
      {:active?, :yes},
      {:embeddings?, 1},
      {:frame_target_bytes, 255},
      {:frame_target_bytes, 1.5}
    ]

    Enum.each(invalid, fn {key, value} ->
      assert {:error, {:invalid_export_option, ^key, ^value}} =
               SpectreMnemonic.export(path("invalid-#{key}-#{inspect(value)}"), [{key, value}])
    end)
  end

  test "reader rejects malformed paths and option containers" do
    assert {:error, {:invalid_mnemonic_path, nil}} = Reader.read(nil)
    assert {:error, {:invalid_mnemonic_path, ""}} = Reader.stream("")

    assert {:error, {:invalid_mnemonic_options, %{trusted: true}}} =
             Reader.read(path("missing"), %{trusted: true})

    assert {:error, {:invalid_mnemonic_options, [:invalid]}} =
             Reader.stream(path("missing"), [:invalid])
  end

  test "writer output satisfies the manifest and record envelopes" do
    scope = {:subject, "schema-writer"}
    export_path = path("writer-schema")

    {:ok, _memory} =
      SpectreMnemonic.signal("format validation memory", scope: scope, persist?: true)

    assert {:ok, _report} = SpectreMnemonic.export(export_path, scope: scope, mode: :full)
    assert {:ok, frames} = Reader.read(export_path)

    assert [%{"section" => "manifest", "data" => manifest} | _rest] = frames
    assert manifest["library_version"] == to_string(Application.spec(:spectre_mnemonic, :vsn))

    assert Enum.all?(
             ~w(format format_version library_version namespace scope scope_digest privacy_mode created_at counts content_digest),
             &Map.has_key?(manifest, &1)
           )

    frames
    |> Enum.filter(&(&1["section"] in @sections))
    |> Enum.flat_map(& &1["data"])
    |> Enum.each(fn record ->
      assert Enum.all?(
               ~w(family id namespace scope_digest inserted_at),
               &Map.has_key?(record, &1)
             )
    end)
  end

  test "manifest requires every normative field" do
    frames = valid_frames()

    Enum.each(
      ~w(format format_version library_version namespace scope scope_digest privacy_mode created_at counts content_digest),
      fn field ->
        invalid = update_data(frames, "manifest", &Map.delete(&1, field))
        write_frames(path("manifest-missing-#{field}"), invalid)

        assert {:error, {:invalid_mnemonic_schema, 1, "manifest", :required_fields}} =
                 Reader.read(path("manifest-missing-#{field}"))
      end
    )
  end

  test "manifest validates field types, digests, timestamps, privacy, and counts" do
    frames = valid_frames()

    invalid = [
      {"format", nil, :format},
      {"format_version", "1", :format_version},
      {"library_version", "", :library_version},
      {"namespace", "", :namespace},
      {"scope", 42, :scope},
      {"scope_digest", "ABC", :scope_digest},
      {"privacy_mode", "private", :privacy_mode},
      {"created_at", "yesterday", :created_at},
      {"content_digest", String.duplicate("A", 64), :content_digest},
      {"counts", Map.delete(zero_counts(), "nodes"), :counts},
      {"counts", Map.put(zero_counts(), "nodes", -1), :counts},
      {"counts", Map.put(zero_counts(), "extra", 0), :counts}
    ]

    Enum.with_index(invalid, fn {field, value, reason}, index ->
      invalid_frames = update_data(frames, "manifest", &Map.put(&1, field, value))
      invalid_path = path("manifest-value-#{index}")
      write_frames(invalid_path, invalid_frames)

      assert {:error, {:invalid_mnemonic_schema, 1, "manifest", ^reason}} =
               Reader.read(invalid_path)
    end)
  end

  test "trailer accepts only its required well-typed fields" do
    frames = valid_frames()
    trailer_sequence = length(frames)

    invalid = [
      {&Map.delete(&1, "counts"), :required_fields},
      {&Map.put(&1, "extra", true), :only_known_fields},
      {&Map.put(&1, "counts", %{}), :counts},
      {&Map.put(&1, "content_digest", "short"), :content_digest}
    ]

    Enum.with_index(invalid, fn {mutation, reason}, index ->
      invalid_frames = update_data(frames, "trailer", mutation)
      invalid_path = path("trailer-#{index}")
      write_frames(invalid_path, invalid_frames)

      assert {:error, {:invalid_mnemonic_schema, ^trailer_sequence, "trailer", ^reason}} =
               Reader.read(invalid_path)
    end)
  end

  test "every content record requires a valid common envelope" do
    base = envelope("node-1")

    invalid = [
      {Map.delete(base, "family"), :required_fields},
      {Map.put(base, "family", ""), :family},
      {Map.put(base, "id", ""), :id},
      {Map.put(base, "namespace", ""), :namespace},
      {Map.put(base, "scope_digest", "bad"), :scope_digest},
      {Map.put(base, "inserted_at", "tomorrow"), :inserted_at},
      {"not-an-object", :record_not_an_object}
    ]

    Enum.with_index(invalid, fn {record, reason}, index ->
      invalid_frames = valid_frames(%{"nodes" => [record]})
      invalid_path = path("record-envelope-#{index}")
      write_frames(invalid_path, invalid_frames)

      assert {:error, {:invalid_mnemonic_schema, 2, "nodes", {:record, 0, ^reason}}} =
               Reader.read(invalid_path)
    end)
  end

  test "edge records validate endpoints, relation, and normalized weight" do
    edge =
      envelope("edge-1")
      |> Map.merge(%{
        "source_id" => "left",
        "target_id" => "right",
        "relation" => "supports",
        "weight" => 0.8
      })

    invalid = [
      {"source_id", nil, :source_id},
      {"source_id", "", :source_id},
      {"target_id", nil, :target_id},
      {"target_id", "", :target_id},
      {"relation", "", :relation},
      {"weight", -0.01, :weight},
      {"weight", 1.01, :weight},
      {"weight", "heavy", :weight}
    ]

    Enum.with_index(invalid, fn {field, value, reason}, index ->
      frames = valid_frames(%{"edges" => [Map.put(edge, field, value)]})
      invalid_path = path("edge-#{index}")
      write_frames(invalid_path, frames)

      assert {:error, {:invalid_mnemonic_schema, 3, "edges", {:record, 0, ^reason}}} =
               Reader.read(invalid_path)
    end)
  end

  test "cluster records validate titles and homogeneous member ids" do
    cluster =
      envelope("cluster-1")
      |> Map.merge(%{"title" => "release", "moment_ids" => ["one", "two"]})

    invalid = [
      {"title", nil, :title},
      {"title", "", :title},
      {"moment_ids", nil, :moment_ids},
      {"moment_ids", ["one", 2], :moment_ids},
      {"moment_ids", ["one", ""], :moment_ids}
    ]

    Enum.with_index(invalid, fn {field, value, reason}, index ->
      frames =
        %{"clusters" => [Map.put(cluster, field, value)]}
        |> valid_frames()
        |> put_in([Access.at(0), "data", "privacy_mode"], "full")

      invalid_path = path("cluster-#{index}")
      write_frames(invalid_path, frames)

      assert {:error, {:invalid_mnemonic_schema, 4, "clusters", {:record, 0, ^reason}}} =
               Reader.read(invalid_path)
    end)
  end

  test "top-level frame shape and content arrays are strict" do
    invalid_path = path("top-level-extra")
    write_frames(invalid_path, [%{"section" => "nodes", "data" => [], "extra" => true}])
    assert {:error, {:invalid_mnemonic_frame, 1}} = Reader.read(invalid_path)

    invalid_path = path("content-object")
    write_frames(invalid_path, [%{"section" => "nodes", "data" => %{}}])

    assert {:error, {:invalid_mnemonic_schema, 1, "nodes", :content_not_an_array}} =
             Reader.read(invalid_path)

    invalid_path = path("unknown-section")
    write_frames(invalid_path, [%{"section" => "unknown", "data" => []}])
    assert {:error, :invalid_mnemonic_sections} = Reader.read(invalid_path)
  end

  test "structure privacy rejects every raw or embedding-bearing field" do
    Enum.with_index(
      ~w(text input summary statement answer vector binary_signature embedding ciphertext iv tag aad),
      fn field, index ->
        record_id = "private-#{index}"
        record = Map.put(envelope(record_id), field, "forbidden")
        frames = valid_frames(%{"nodes" => [record]})
        invalid_path = path("structure-private-#{index}")
        write_frames(invalid_path, frames)

        assert {:error, {:mnemonic_privacy_violation, ^record_id, ^field}} =
                 Reader.read(invalid_path)
      end
    )
  end

  test "secret payload fields are rejected in every privacy mode" do
    Enum.with_index(~w(structure full redacted), fn mode, mode_index ->
      Enum.with_index(~w(plaintext ciphertext iv tag aad vector embedding text), fn field,
                                                                                    index ->
        record_id = "secret-#{mode_index}-#{index}"

        record =
          envelope(record_id)
          |> Map.merge(%{"family" => "secrets", "secret" => true, field => "forbidden"})

        frames =
          %{"nodes" => [record]}
          |> valid_frames()
          |> update_data("manifest", &Map.put(&1, "privacy_mode", mode))

        invalid_path = path(record_id)
        write_frames(invalid_path, frames)

        assert {:error, {:mnemonic_privacy_violation, ^record_id, ^field}} =
                 Reader.read(invalid_path)
      end)
    end)
  end

  test "content chunks must be consecutive and in normative order" do
    frames = valid_frames()
    manifest = Enum.at(frames, 0)
    nodes = Enum.at(frames, 1)
    edges = Enum.at(frames, 2)

    invalid_path = path("non-consecutive-chunks")
    write_frames(invalid_path, [manifest, nodes, edges, nodes])
    assert {:error, :invalid_mnemonic_sections} = Reader.read(invalid_path)

    invalid_path = path("starts-at-edges")
    write_frames(invalid_path, [manifest, edges])
    assert {:error, :invalid_mnemonic_sections} = Reader.read(invalid_path)
  end

  test "reader rejects declared, compressed, and expanded frame limit violations" do
    maximum = FileFrame.max_payload_bytes()
    too_large_path = path("declared-too-large")

    File.write!(
      too_large_path,
      <<"SMNE", 1, 1::unsigned-64, maximum + 1::unsigned-32, 0::unsigned-32>>
    )

    assert {:error, {:mnemonic_frame_too_large, 1, declared}} = Reader.read(too_large_path)
    assert declared == maximum + 1

    Application.put_env(:spectre_mnemonic, :max_frame_bytes, 256)
    expanded = :zlib.gzip(String.duplicate("x", 1_000))
    expanded_path = path("expanded-too-large")
    write_raw_frame(expanded_path, expanded)

    assert {:error, {:mnemonic_expanded_frame_too_large, 1}} = Reader.read(expanded_path)
  end

  test "writer refuses a single record that cannot fit the requested frame" do
    scope = {:subject, "oversized-record"}

    {:ok, _memory} =
      SpectreMnemonic.signal(String.duplicate("large-memory-payload ", 100),
        scope: scope,
        persist?: true
      )

    assert {:error, {:mnemonic_record_too_large, "nodes", _id}} =
             SpectreMnemonic.export(path("oversized-record"),
               scope: scope,
               mode: :full,
               frame_target_bytes: 256
             )
  end

  test "canonical JSON and the published schema remain deterministic and parseable" do
    assert CanonicalJSON.encode(%{"z" => 1, "a" => %{"d" => 4, "b" => 2}}) ==
             ~s({"a":{"b":2,"d":4},"z":1})

    schema =
      "priv/mnemonic_schema_v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"

    assert Enum.sort(Map.keys(schema["$defs"])) ==
             Enum.sort(
               ~w(clusterRecord clustersFrame counts digest edgeRecord edgesFrame genericContentFrame governanceFrame knowledgeFrame manifestFrame modelsFrame nodesFrame recordEnvelope trailerFrame)
             )
  end

  test "every frame emitted by the writer validates against the published JSON Schema" do
    scope = {:subject, "schema-writer-output"}
    output_path = path("schema-writer-output")

    {:ok, %{moment: left}} = SpectreMnemonic.signal("schema left", scope: scope)
    {:ok, %{moment: right}} = SpectreMnemonic.signal("schema right", scope: scope)
    {:ok, _edge} = SpectreMnemonic.link(left.id, :supports, right.id, scope: scope)
    assert {:ok, _episodes} = SpectreMnemonic.Atlas.materialize(scope: scope)
    assert {:ok, _report} = SpectreMnemonic.export(output_path, scope: scope)
    assert {:ok, frames} = Reader.read(output_path)

    schema = "priv/mnemonic_schema_v1.json" |> File.read!() |> Jason.decode!()

    Enum.each(frames, fn frame ->
      assert SpectreMnemonic.JSONSchemaTestValidator.valid?(schema, frame)
    end)
  end

  defp valid_frames(content \\ %{}) do
    content_frames =
      Enum.map(@sections, fn section ->
        %{"section" => section, "data" => Map.get(content, section, [])}
      end)

    counts = Map.new(content_frames, &{&1["section"], length(&1["data"])})
    digest = content_digest(content_frames)

    manifest = %{
      "format" => "spectre-mnemonic",
      "format_version" => 1,
      "library_version" => "0.1.0",
      "namespace" => @namespace,
      "scope" => "{:subject, \"format\"}",
      "scope_digest" => @scope_digest,
      "privacy_mode" => "structure",
      "created_at" => "1970-01-01T00:00:00Z",
      "counts" => counts,
      "content_digest" => digest
    }

    trailer = %{"counts" => counts, "content_digest" => digest}

    [%{"section" => "manifest", "data" => manifest} | content_frames] ++
      [%{"section" => "trailer", "data" => trailer}]
  end

  defp envelope(id) do
    %{
      "family" => "moments",
      "id" => id,
      "namespace" => @namespace,
      "scope_digest" => @scope_digest,
      "inserted_at" => "1970-01-01T00:00:00Z"
    }
  end

  defp zero_counts, do: Map.new(@sections, &{&1, 0})

  defp update_data(frames, section, fun) do
    Enum.map(frames, fn
      %{"section" => ^section, "data" => data} = frame -> %{frame | "data" => fun.(data)}
      frame -> frame
    end)
  end

  defp content_digest(frames) do
    frames
    |> Enum.map_join("", &CanonicalJSON.encode/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write_frames(path, frames) do
    binary =
      frames
      |> Enum.with_index(1)
      |> Enum.map(fn {frame, sequence} -> encode_frame(frame, sequence) end)
      |> IO.iodata_to_binary()

    File.write!(path, binary)
  end

  defp encode_frame(frame, sequence) do
    payload = frame |> CanonicalJSON.encode() |> :zlib.gzip()

    <<"SMNE", 1, sequence::unsigned-64, byte_size(payload)::unsigned-32,
      :erlang.crc32(payload)::unsigned-32, payload::binary>>
  end

  defp write_raw_frame(path, payload) do
    File.write!(
      path,
      <<"SMNE", 1, 1::unsigned-64, byte_size(payload)::unsigned-32,
        :erlang.crc32(payload)::unsigned-32, payload::binary>>
    )
  end

  defp path(name), do: Path.expand("mnemonic_data/#{name}.mnemonic")
end
