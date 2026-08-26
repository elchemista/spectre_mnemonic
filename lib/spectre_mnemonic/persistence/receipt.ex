defmodule SpectreMnemonic.Persistence.Receipt do
  @moduledoc false

  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.WriteReceipt

  @type write_result :: %{
          store: term(),
          role: term(),
          result: :ok | :pending | {:error, term()}
        }

  @spec build(Record.t(), [write_result()], boolean()) :: WriteReceipt.t()
  def build(record, results, idempotent?) do
    {_primary, replicas} = Enum.split_with(results, &(&1.role == :primary))

    replica_statuses =
      Map.new(replicas, fn replica ->
        status =
          case replica.result do
            :ok -> :committed
            :pending -> :pending
            {:error, _reason} -> :pending_repair
          end

        {replica.store, status}
      end)

    %WriteReceipt{
      operation_id: record.operation_id || record.dedupe_key || record.id,
      commit_id: record.commit_id || record.id,
      batch_id: record.batch_id,
      status: :committed,
      primary: :committed,
      replicas: replica_statuses,
      repair_required?: Enum.any?(replicas, &(&1.result != :ok)),
      idempotent?: idempotent?,
      record: record,
      stores: results
    }
  end
end
