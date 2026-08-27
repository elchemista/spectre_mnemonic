defmodule SpectreMnemonic.Migration do
  @moduledoc """
  Explicit, idempotent durable-memory repartitioning.

  Mnemonic never guesses ownership of legacy shared memory. The host assigns
  each visible durable record to one destination scope or `:skip`. Repartition
  copies records and leaves the source untouched; erase it only after the host
  has verified the destination.
  """

  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.WriteReceipt

  @internal_families [:batch_begins, :batch_commits, :repair_jobs, :erasure_markers]

  @type assignment :: term() | :skip
  @type report :: %{
          scanned: non_neg_integer(),
          migrated: non_neg_integer(),
          idempotent: non_neg_integer(),
          skipped: non_neg_integer(),
          source_erased?: boolean()
        }

  @doc "Copies visible durable records according to a host-owned assignment callback."
  @spec repartition(keyword(), keyword(), module() | (Record.t() -> assignment())) ::
          {:ok, report()} | {:error, term()}
  def repartition(source_opts, destination_opts, assigner)
      when is_list(source_opts) and is_list(destination_opts) do
    with :ok <- validate_opts(source_opts, :source),
         :ok <- validate_opts(destination_opts, :destination),
         :ok <- validate_assigner(assigner),
         {:ok, records} <- replay(source_opts) do
      records
      |> Enum.reject(&(&1.family in @internal_families))
      |> Enum.reduce_while({:ok, empty_report()}, fn record, {:ok, report} ->
        migrate_assigned(record, assigner, destination_opts, report)
      end)
    end
  end

  def repartition(source_opts, destination_opts, _assigner),
    do: {:error, {:invalid_repartition_options, source_opts, destination_opts}}

  @doc "Copies every visible durable record from one explicit scope to another."
  @spec migrate_partition(keyword(), keyword()) :: {:ok, report()} | {:error, term()}
  def migrate_partition(source_opts, destination_opts) do
    with {:ok, destination_scope} <- fetch_scope(destination_opts, :destination) do
      repartition(source_opts, destination_opts, fn _record -> destination_scope end)
    end
  end

  @doc "Migrates one schema-versioned Spectre Instance scope to another."
  @spec migrate_instance_partition(map(), map(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def migrate_instance_partition(old_ref, new_ref, opts \\ []) do
    with {:ok, old_scope} <- instance_scope(old_ref),
         {:ok, new_scope} <- instance_scope(new_ref),
         {:ok, report} <-
           migrate_partition(
             Keyword.put(opts, :scope, old_scope),
             Keyword.put(opts, :scope, new_scope)
           ),
         {:ok, erased?} <- maybe_erase_source(old_scope, opts) do
      {:ok, %{report | source_erased?: erased?}}
    end
  end

  @spec replay(keyword()) :: {:ok, [Record.t()]} | {:error, term()}
  defp replay(opts), do: Context.with(opts, &Manager.replay/1)

  @spec migrate_assigned(Record.t(), module() | function(), keyword(), report()) ::
          {:cont, {:ok, report()}} | {:halt, {:error, term()}}
  defp migrate_assigned(record, assigner, destination_opts, report) do
    report = %{report | scanned: report.scanned + 1}

    case assignment(assigner, record) do
      {:ok, :skip} ->
        {:cont, {:ok, %{report | skipped: report.skipped + 1}}}

      {:ok, scope} ->
        case copy_record(record, scope, destination_opts) do
          {:ok, %WriteReceipt{idempotent?: true}} ->
            {:cont,
             {:ok,
              %{
                report
                | migrated: report.migrated + 1,
                  idempotent: report.idempotent + 1
              }}}

          {:ok, %WriteReceipt{}} ->
            {:cont, {:ok, %{report | migrated: report.migrated + 1}}}

          {:ok, _legacy_result} ->
            {:cont, {:ok, %{report | migrated: report.migrated + 1}}}

          {:error, reason} ->
            {:halt, {:error, {:repartition_failed, record.id, reason, report}}}
        end

      {:error, reason} ->
        {:halt, {:error, {:repartition_assignment_failed, record.id, reason, report}}}
    end
  end

  @spec copy_record(Record.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp copy_record(record, scope, destination_opts) do
    destination_opts = Keyword.put(destination_opts, :scope, scope)

    Context.with(destination_opts, fn opts ->
      namespace = Identity.namespace!(opts)
      operation_id = migration_operation_id(record, namespace, scope, destination_opts)
      migrated = recontextualize(record, namespace, scope, operation_id)

      Manager.put(
        migrated,
        opts
        |> Keyword.put(:operation_id, operation_id)
        |> Keyword.put(:scope, scope)
      )
    end)
  end

  @spec recontextualize(Record.t(), binary(), term(), binary()) :: Record.t()
  defp recontextualize(record, namespace, scope, operation_id) do
    %{
      record
      | schema_version: 2,
        storage_id: nil,
        namespace: namespace,
        scope: scope,
        payload: put_context(record.payload, namespace, scope),
        metadata: put_context(record.metadata, namespace, scope),
        operation_id: operation_id,
        commit_id: nil,
        batch_id: nil,
        revision: 1,
        digest: nil,
        dedupe_key: nil
    }
  end

  @spec put_context(term(), binary(), term()) :: term()
  defp put_context(value, namespace, scope) when is_map(value) do
    value
    |> put_existing_or_atom(:namespace, "namespace", namespace)
    |> put_existing_or_atom(:scope, "scope", scope)
    |> update_nested_context(:metadata, namespace, scope)
    |> update_nested_context(:payload, namespace, scope)
    |> update_nested_context(:record, namespace, scope)
  end

  defp put_context(value, _namespace, _scope), do: value

  @spec put_existing_or_atom(map(), atom(), binary(), term()) :: map()
  defp put_existing_or_atom(value, atom_key, string_key, context) do
    value =
      if Map.has_key?(value, atom_key) or not is_struct(value),
        do: Map.put(value, atom_key, context),
        else: value

    if Map.has_key?(value, string_key),
      do: Map.put(value, string_key, context),
      else: value
  end

  @spec update_nested_context(map(), atom(), binary(), term()) :: map()
  defp update_nested_context(value, key, namespace, scope) do
    string_key = Atom.to_string(key)

    value
    |> update_context_key(key, namespace, scope)
    |> update_context_key(string_key, namespace, scope)
  end

  @spec update_context_key(map(), atom() | binary(), binary(), term()) :: map()
  defp update_context_key(value, key, namespace, scope) do
    case Map.fetch(value, key) do
      {:ok, nested} when is_map(nested) ->
        Map.put(value, key, put_context(nested, namespace, scope))

      _missing_or_scalar ->
        value
    end
  end

  @spec migration_operation_id(Record.t(), binary(), term(), keyword()) :: binary()
  defp migration_operation_id(record, namespace, scope, opts) do
    migration_id = Keyword.get(opts, :migration_id, "spectre-mnemonic-0.2-repartition")

    digest =
      {migration_id, record.namespace, record.scope, record.family, record.id, namespace, scope}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "migration-" <> digest
  end

  @spec assignment(module() | function(), Record.t()) :: {:ok, assignment()} | {:error, term()}
  defp assignment(assigner, record) do
    result = if is_function(assigner, 1), do: assigner.(record), else: assigner.assign(record)

    case result do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
      scope -> {:ok, scope}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec validate_assigner(term()) :: :ok | {:error, term()}
  defp validate_assigner(assigner) when is_function(assigner, 1), do: :ok

  defp validate_assigner(assigner) when is_atom(assigner) do
    if Code.ensure_loaded?(assigner) and function_exported?(assigner, :assign, 1),
      do: :ok,
      else: {:error, {:invalid_repartition_assigner, assigner}}
  end

  defp validate_assigner(assigner), do: {:error, {:invalid_repartition_assigner, assigner}}

  @spec validate_opts(term(), atom()) :: :ok | {:error, term()}
  defp validate_opts(opts, side) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, {:invalid_repartition_options, side, opts}}
  end

  @spec fetch_scope(keyword(), atom()) :: {:ok, term()} | {:error, term()}
  defp fetch_scope(opts, side) do
    if Keyword.has_key?(opts, :scope),
      do: {:ok, Keyword.get(opts, :scope)},
      else: {:error, {:repartition_scope_required, side}}
  end

  @spec instance_scope(map()) :: {:ok, tuple()} | {:error, term()}
  defp instance_scope(%{schema_version: version, key: key})
       when not is_nil(version) and not is_nil(key),
       do: {:ok, {:spectre, [instance: {version, key}]}}

  defp instance_scope(ref), do: {:error, {:invalid_instance_ref, ref}}

  @spec maybe_erase_source(term(), keyword()) :: {:ok, boolean()} | {:error, term()}
  defp maybe_erase_source(scope, opts) do
    if Keyword.get(opts, :erase_source?, false) do
      erase_opts = opts |> Keyword.delete(:erase_source?) |> Keyword.put(:scope, scope)

      case SpectreMnemonic.erase_partition(erase_opts) do
        {:ok, _report} -> {:ok, true}
        {:error, reason} -> {:error, {:source_erasure_failed, reason}}
      end
    else
      {:ok, false}
    end
  end

  @spec empty_report :: report()
  defp empty_report,
    do: %{scanned: 0, migrated: 0, idempotent: 0, skipped: 0, source_erased?: false}
end
