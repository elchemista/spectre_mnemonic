defmodule SpectreMnemonic.Persistence.Repair do
  @moduledoc false

  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.RecordBuilder
  alias SpectreMnemonic.Persistence.RepairJob
  alias SpectreMnemonic.Persistence.RepairQueue
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Persistence.Writer

  @type store :: Config.store()
  @type write_result :: Writer.write_result()

  @spec dispatch([store()], [store()], Record.t(), keyword()) :: [write_result()]
  def dispatch(replicas, primary_stores, record, opts) do
    Enum.map(replicas, &dispatch_store(&1, primary_stores, record, opts))
  end

  defp dispatch_store(store, primary_stores, record, opts) do
    job = build_job(record, store)
    RepairQueue.enqueue(job)
    persist_job(job, primary_stores, opts)
    start_delivery(job)
    %{store: store.id, role: store.role, result: :pending}
  end

  defp start_delivery(job) do
    case Task.Supervisor.start_child(SpectreMnemonic.SharedTaskSupervisor, fn -> deliver(job) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        RepairQueue.failed(
          job.record.storage_id,
          job.record.commit_id,
          job.target_store,
          reason
        )
    end
  end

  defp build_job(record, store) do
    now = DateTime.utc_now()

    %RepairJob{
      id: "repair:#{record.commit_id}:#{store.id}",
      commit_id: record.commit_id,
      target_store: store.id,
      record: record,
      store: store,
      inserted_at: now,
      updated_at: now
    }
  end

  defp persist_job(job, primary_stores, opts) do
    payload = %{
      id: job.id,
      commit_id: job.commit_id,
      target_store: job.target_store,
      attempts: job.attempts,
      status: job.status,
      record: job.record,
      inserted_at: job.inserted_at
    }

    repair_opts =
      opts
      |> Keyword.delete(:batch_id)
      |> Keyword.delete(:operation_id)
      |> Keyword.put(:dedupe_key, job.id)
      |> Keyword.put(:source_event_id, job.id)

    repair_record = RecordBuilder.build(:repair_jobs, :put, payload, repair_opts)
    Enum.each(primary_stores, &Writer.write(&1, repair_record))
    :ok
  end

  defp deliver(job) do
    case Writer.write(job.store, job.record) do
      %{result: :ok} ->
        RepairQueue.delivered(job.record.storage_id, job.commit_id, job.target_store)

      %{result: {:error, reason}} ->
        RepairQueue.failed(job.record.storage_id, job.commit_id, job.target_store, reason)
    end
  end
end
