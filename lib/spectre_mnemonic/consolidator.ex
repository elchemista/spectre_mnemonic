defmodule SpectreMnemonic.Consolidator do
  @moduledoc """
  Moves selected active focus into durable memory records.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  use GenServer

  alias SpectreMnemonic.{Focus, Knowledge, PersistentMemory}

  @doc "Starts the consolidator process."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Consolidates high-attention moments into persistent memory records."
  def consolidate(opts \\ []) do
    GenServer.call(__MODULE__, {:consolidate, opts})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:consolidate, opts}, _from, state) do
    min_attention = Keyword.get(opts, :min_attention, 1.0)
    now = DateTime.utc_now()

    knowledge =
      Focus.moments()
      |> Enum.filter(&(&1.attention >= min_attention))
      |> Enum.map(fn moment ->
        %Knowledge{
          id: "know_#{System.unique_integer([:positive, :monotonic])}",
          source_id: moment.id,
          text: moment.text,
          vector: moment.vector,
          binary_signature: moment.binary_signature,
          embedding: moment.embedding,
          metadata: %{stream: moment.stream, task_id: moment.task_id, kind: moment.kind},
          inserted_at: now
        }
      end)

    results =
      Enum.map(knowledge, &PersistentMemory.append(:knowledge, &1)) ++
        [
          PersistentMemory.append(:consolidation_jobs, %{
            count: length(knowledge),
            inserted_at: now
          })
        ]

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil ->
        PersistentMemory.compact()
        {:reply, {:ok, knowledge}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
end
