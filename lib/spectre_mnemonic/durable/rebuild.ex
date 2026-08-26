defmodule SpectreMnemonic.Durable.Rebuild do
  @moduledoc false

  alias SpectreMnemonic.Durable.Documents
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Persistence.Config
  alias SpectreMnemonic.Persistence.Replay
  alias SpectreMnemonic.Persistence.Store.Record

  @spec build_stream(keyword()) :: {:ok, map()} | {:error, term()}
  def build_stream(opts) do
    state = Documents.empty_state()

    try do
      config = Config.effective(opts)
      namespace = Identity.namespace!(opts)
      stores = Config.replayable_stores(config)

      case Replay.checked_fold(
             stores,
             state,
             fn %Record{} = record, current ->
               {:cont, Documents.absorb(record, current)}
             end,
             &(&1.namespace in [nil, namespace])
           ) do
        {:ok, rebuilt} ->
          {:ok, rebuilt}

        {:error, failures} ->
          fail(state, {:persistent_memory_replay_failed, failures})
      end
    rescue
      exception ->
        fail(
          state,
          {:persistent_memory_replay_exception, exception.__struct__,
           Exception.message(exception)}
        )
    catch
      :exit, reason ->
        fail(state, {:persistent_memory_replay_exit, reason})

      kind, reason ->
        fail(state, {:persistent_memory_replay_failure, kind, reason})
    end
  end

  @spec replace(map(), Enumerable.t(), Enumerable.t()) :: map()
  def replace(state, replayed, pending \\ []) do
    state
    |> Documents.reset()
    |> Documents.index_records(replayed)
    |> Documents.index_records(pending)
  end

  defp fail(state, reason) do
    Documents.destroy(state)
    {:error, reason}
  end
end
