defmodule SpectreMnemonic.Persistence.Writer do
  @moduledoc false

  require Logger

  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.Telemetry

  @type store :: SpectreMnemonic.Persistence.Config.store()
  @type config :: keyword()
  @type write_result :: %{
          store: term(),
          role: term(),
          result: :ok | :pending | {:error, term()}
        }

  @spec write(store(), Record.t()) :: write_result()
  def write(store, record) do
    started = System.monotonic_time()

    result =
      try do
        normalize_result(store.adapter.put(record, store.opts))
      rescue
        exception -> {:error, {exception.__struct__, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    duration = System.monotonic_time() - started
    emit_event(store, record, result, duration)
    %{store: store.id, role: store.role, result: result}
  end

  @spec evaluate(config(), [store()], [write_result()]) :: :ok | {:error, term()}
  def evaluate(config, stores, results) do
    failure_mode = Keyword.get(config, :failure_mode, :best_effort)

    primary_ids =
      stores |> Enum.filter(&(&1.role == :primary)) |> Enum.map(& &1.id) |> MapSet.new()

    failed = Enum.filter(results, &match?({:error, _reason}, &1.result))
    primary_failed = Enum.any?(failed, &MapSet.member?(primary_ids, &1.store))

    cond do
      failed == [] ->
        :ok

      failure_mode == :strict ->
        {:error, {:persistent_memory_failed, failed}}

      primary_failed ->
        {:error, {:primary_persistent_memory_failed, failed}}

      true ->
        Logger.warning("secondary persistent memory write failed: #{inspect(failed)}")
        :ok
    end
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(other), do: {:error, {:unexpected_adapter_result, other}}

  defp emit_event(store, record, result, duration) do
    event = if store.role == :primary, do: [:primary, :commit], else: [:replica, :write]

    Telemetry.emit(event, %{duration: duration}, %{
      store: store.id,
      family: record.family,
      outcome: if(result == :ok, do: :ok, else: :error)
    })

    Telemetry.emit([:persistent_memory, :write], %{duration: duration}, %{
      store: store.id,
      family: record.family,
      outcome: if(result == :ok, do: :ok, else: :error)
    })
  end
end
