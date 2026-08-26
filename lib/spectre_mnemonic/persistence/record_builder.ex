defmodule SpectreMnemonic.Persistence.RecordBuilder do
  @moduledoc false

  alias SpectreMnemonic.Erasure
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Family
  alias SpectreMnemonic.Persistence.Store.Record

  @spec build(atom(), atom(), term(), keyword()) :: Record.t()
  def build(family, operation, payload, opts) do
    now = DateTime.utc_now()
    namespace = Identity.namespace!(opts)
    scope = context_scope(payload, opts)
    id = Keyword.get(opts, :record_id) || Identity.generate("pmem", opts)
    payload_id = payload_id(payload)
    source_event_id = Keyword.get(opts, :source_event_id) || payload_id || id
    operation_id = operation_id(opts)
    dedupe_source = dedupe_source(family, payload, source_event_id)

    dedupe_key =
      Keyword.get(opts, :dedupe_key) ||
        operation_dedupe_key(
          operation_id,
          namespace,
          scope,
          family,
          operation,
          dedupe_source,
          opts
        )

    record = %Record{
      id: id,
      storage_id: Keyword.get(opts, :storage_id, namespace),
      namespace: namespace,
      scope: scope,
      family: family,
      operation: operation,
      operation_id: operation_id,
      commit_id: commit_id(operation_id, family, dedupe_key),
      batch_id: Keyword.get(opts, :batch_id),
      revision: Keyword.get(opts, :revision, 1),
      payload: payload,
      dedupe_key: dedupe_key,
      inserted_at: now,
      source_event_id: source_event_id,
      metadata:
        opts
        |> Keyword.get(:metadata, %{})
        |> Map.new()
        |> Identity.put_context(Keyword.put(opts, :scope, scope))
        |> maybe_put_erasure_generation(opts)
    }

    %{record | digest: record |> digest() |> Base.encode16(case: :lower)}
  end

  @spec prepare_payload_context(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def prepare_payload_context(payload, opts) do
    namespace = Identity.namespace!(opts)
    scope = context_scope(payload, opts)

    with :ok <- Scope.validate_assignable_context(payload, namespace, scope) do
      {:ok, put_payload_context(payload, namespace, scope)}
    end
  end

  @spec normalize(Record.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def normalize(%Record{} = record, opts) do
    record = Record.upgrade(record)
    expected = Identity.namespace!(opts)

    with :ok <- validate_record_namespace(record, expected),
         {:ok, scope} <- record_scope(record, opts),
         :ok <- Scope.validate_assignable_context(record.metadata, expected, scope),
         :ok <- Scope.validate_assignable_context(record.payload, expected, scope) do
      {:ok, build_normalized_record(record, expected, scope, opts)}
    end
  end

  @spec put_erasure_generation(keyword()) :: keyword()
  def put_erasure_generation(opts) do
    case Erasure.generation(opts) do
      generation when is_binary(generation) -> Keyword.put(opts, :erasure_generation, generation)
      _missing -> Keyword.delete(opts, :erasure_generation)
    end
  end

  @spec digest(Record.t()) :: binary()
  def digest(%Record{family: :tombstones, payload: payload} = record) when is_map(payload) do
    digest_record(record, Map.drop(payload, [:forgotten_at, "forgotten_at"]))
  end

  def digest(record), do: digest_record(record, record.payload)

  @spec payload_id(term()) :: binary() | nil
  def payload_id(payload) when is_map(payload) do
    case map_value(payload, :id) do
      id when is_binary(id) -> id
      id when is_atom(id) -> Atom.to_string(id)
      _other -> nil
    end
  end

  def payload_id(_payload), do: nil

  @spec tombstone_target(term()) :: {:ok, {atom(), binary()}} | :error
  def tombstone_target(payload) when is_map(payload) do
    with {:ok, family} <- normalize_family(map_value(payload, :family)),
         id when is_binary(id) <- payload_id(payload) do
      {:ok, {family, id}}
    else
      _invalid -> :error
    end
  end

  def tombstone_target(_payload), do: :error

  @spec map_value(map(), atom()) :: term()
  def map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp operation_id(opts) do
    case Keyword.get(opts, :operation_id) do
      value when is_binary(value) and value != "" -> value
      _missing_or_invalid -> Identity.uuid7()
    end
  end

  defp operation_dedupe_key(operation_id, namespace, scope, family, operation, source, opts) do
    if Keyword.has_key?(opts, :operation_id) do
      "op:#{operation_id}:#{family}:#{operation}:#{source}"
    else
      "#{namespace}:#{scope_key(scope)}:#{family}:#{operation}:#{source}"
    end
  end

  defp commit_id(operation_id, family, dedupe_key) do
    {operation_id, family, dedupe_key}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp build_normalized_record(record, namespace, scope, opts) do
    payload = put_payload_context(record.payload, namespace, scope)
    operation_id = fallback(record.operation_id, operation_id(opts))
    source_event_id = source_event_id(record)
    dedupe_key = normalized_dedupe_key(record, payload, operation_id, namespace, scope, opts)

    normalized = %{
      record
      | schema_version: 2,
        storage_id: fallback(record.storage_id, Keyword.get(opts, :storage_id, namespace)),
        namespace: namespace,
        scope: scope,
        payload: payload,
        operation_id: operation_id,
        commit_id: normalized_commit_id(record, operation_id, dedupe_key),
        batch_id: fallback(record.batch_id, Keyword.get(opts, :batch_id)),
        revision: fallback(record.revision, Keyword.get(opts, :revision, 1)),
        source_event_id: source_event_id,
        dedupe_key: dedupe_key,
        metadata: normalized_metadata(record, scope, opts),
        digest: nil
    }

    %{normalized | digest: normalized_digest(record.digest, normalized)}
  end

  defp source_event_id(record) do
    Enum.find([record.source_event_id, payload_id(record.payload), record.id], &(not is_nil(&1)))
  end

  defp normalized_dedupe_key(
         %Record{dedupe_key: key},
         _payload,
         _operation_id,
         _namespace,
         _scope,
         _opts
       )
       when is_binary(key),
       do: key

  defp normalized_dedupe_key(record, payload, operation_id, namespace, scope, opts) do
    source = dedupe_source(record.family, payload, source_event_id(record))

    operation_dedupe_key(
      operation_id,
      namespace,
      scope,
      record.family,
      record.operation,
      source,
      opts
    )
  end

  defp normalized_commit_id(%Record{commit_id: id}, _operation_id, _dedupe_key)
       when is_binary(id),
       do: id

  defp normalized_commit_id(record, operation_id, dedupe_key),
    do: commit_id(operation_id, record.family, dedupe_key)

  defp normalized_metadata(record, scope, opts) do
    record.metadata
    |> Map.new()
    |> Identity.put_context(Keyword.put(opts, :scope, scope))
    |> maybe_put_erasure_generation(opts)
  end

  defp normalized_digest(value, _record) when is_binary(value), do: value
  defp normalized_digest(_value, record), do: Base.encode16(digest(record), case: :lower)

  defp fallback(nil, default), do: default
  defp fallback(value, _default), do: value

  defp maybe_put_erasure_generation(metadata, opts) do
    case Keyword.get(opts, :erasure_generation) do
      generation when is_binary(generation) -> Map.put(metadata, :erasure_generation, generation)
      _missing -> metadata
    end
  end

  defp validate_record_namespace(%Record{namespace: namespace}, expected)
       when namespace in [nil, expected],
       do: :ok

  defp validate_record_namespace(%Record{namespace: namespace}, expected),
    do: {:error, {:namespace_mismatch, expected, namespace}}

  defp record_scope(record, opts) do
    requested = Keyword.get(opts, :scope)

    cond do
      Keyword.has_key?(opts, :scope) and not is_nil(record.scope) and record.scope != requested ->
        {:error, {:scope_mismatch, requested, record.scope}}

      Keyword.has_key?(opts, :scope) ->
        {:ok, requested}

      not is_nil(record.scope) ->
        {:ok, record.scope}

      true ->
        {:ok, Scope.scope(record.payload)}
    end
  end

  defp put_payload_context(payload, namespace, scope) when is_map(payload) do
    payload
    |> put_context_field(:namespace, namespace)
    |> put_context_field(:scope, scope)
  end

  defp put_payload_context(payload, _namespace, _scope), do: payload

  defp put_context_field(payload, key, value) do
    if is_struct(payload) and not Map.has_key?(payload, key),
      do: payload,
      else: Map.put(payload, key, value)
  end

  @spec context_scope(term(), keyword()) :: term()
  def context_scope(payload, opts) do
    if Keyword.has_key?(opts, :scope), do: Keyword.get(opts, :scope), else: Scope.scope(payload)
  end

  defp dedupe_source(:tombstones, payload, source_event_id) do
    case tombstone_target(payload) do
      {:ok, {family, id}} -> "#{family}:#{id}"
      :error -> to_string(source_event_id)
    end
  end

  defp dedupe_source(_family, _payload, source_event_id), do: to_string(source_event_id)

  defp scope_key(scope) do
    scope
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp digest_record(record, payload) do
    {
      record.namespace,
      record.scope,
      record.family,
      record.operation,
      record.source_event_id,
      payload
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp normalize_family(family) when is_atom(family), do: {:ok, family}
  defp normalize_family(family) when is_binary(family), do: Family.from_string(family)
  defp normalize_family(_family), do: :error
end
