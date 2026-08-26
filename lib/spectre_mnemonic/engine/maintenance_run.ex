defmodule SpectreMnemonic.Engine.MaintenanceRun do
  @moduledoc false

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Durable.Index
  alias SpectreMnemonic.Engine.Context
  alias SpectreMnemonic.Engine.PartitionExecutor
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.Engine.Runtime
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Graph.Plasticity
  alias SpectreMnemonic.Knowledge.Consolidator
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.Manager

  @doc false
  @spec run(Runtime.t(), keyword()) :: map() | {:error, term()}
  def run(%Runtime{} = runtime, config) do
    Context.with([engine: runtime.config.ref], fn engine_opts ->
      run_checked(runtime, config, engine_opts)
    end)
  end

  @spec run_checked(Runtime.t(), keyword(), keyword()) :: map()
  defp run_checked(runtime, config, engine_opts) do
    base_opts =
      engine_opts
      |> Keyword.put(:min_attention, Keyword.get(config, :min_attention, 1.0))
      |> Keyword.put(:graph_depth, Keyword.get(config, :graph_depth, 1))
      |> Keyword.put(:stale_after_ms, Keyword.fetch!(config, :stale_after_ms))

    partitions = known_partitions(runtime, base_opts)

    consolidation =
      partition_results(partitions, base_opts, fn opts ->
        case Consolidator.consolidate(opts) do
          {:ok, records} -> {:ok, length(records)}
          {:error, reason} -> {:error, reason}
        end
      end)

    decay = partition_results(partitions, base_opts, &Governance.decay/1)
    graph_decay = partition_results(partitions, base_opts, &Plasticity.decay/1)
    attention_decay = partition_results(partitions, base_opts, &Focus.decay_attention_all/1)
    compact = compact_partitions(partitions, base_opts, Keyword.get(config, :mode, :all))
    rebuild = Index.rebuild(base_opts)

    %{
      partitions: partitions,
      consolidation: consolidation,
      decay: decay,
      graph_decay: graph_decay,
      attention_decay: attention_decay,
      compact: compact,
      durable_index: rebuild
    }
  end

  @spec known_partitions(Runtime.t(), keyword()) :: [{binary(), term()}]
  defp known_partitions(runtime, opts) do
    namespace = runtime.config.internal_namespace

    durable =
      case Manager.replay_fold(opts, MapSet.new(), fn record, partitions ->
             {:cont, MapSet.put(partitions, {record.namespace, Scope.scope(record)})}
           end) do
        {:ok, partitions} -> MapSet.to_list(partitions)
        {:error, _reason} -> []
      end

    [{namespace, nil} | Projection.partitions(runtime) ++ durable]
    |> Enum.filter(fn {record_namespace, _scope} -> record_namespace == namespace end)
    |> Enum.uniq()
    |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))
  end

  @spec partition_results([{binary(), term()}], keyword(), (keyword() -> term())) :: map()
  defp partition_results(partitions, base_opts, fun) do
    results =
      Enum.map(partitions, fn {namespace, scope} ->
        opts = base_opts |> Keyword.put(:namespace, namespace) |> Keyword.put(:scope, scope)

        result =
          PartitionExecutor.trans(
            PartitionExecutor.key(opts),
            fn -> fun.(opts) end,
            opts
          )

        {{namespace, scope}, result}
      end)

    %{partitions: length(partitions), results: results}
  end

  @spec compact_partitions([{binary(), term()}], keyword(), atom()) :: term()
  defp compact_partitions(_partitions, _base_opts, :none), do: {:ok, :skipped}

  defp compact_partitions(_partitions, base_opts, :physical),
    do: Manager.compact(Keyword.put(base_opts, :mode, :physical))

  defp compact_partitions(partitions, base_opts, mode) when mode in [:semantic, :all] do
    semantic =
      partition_results(partitions, base_opts, fn opts ->
        Manager.compact(Keyword.put(opts, :mode, :semantic))
      end)

    if mode == :all do
      %{
        mode: :all,
        semantic: semantic,
        physical: Manager.compact(Keyword.put(base_opts, :mode, :physical))
      }
    else
      semantic
    end
  end

  defp compact_partitions(_partitions, _base_opts, mode),
    do: {:error, {:invalid_compact_mode, mode}}
end
