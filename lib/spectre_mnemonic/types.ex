defmodule SpectreMnemonic.Signal do
  @moduledoc "Raw input accepted by `SpectreMnemonic.signal/2` before it becomes a moment."
  defstruct [:id, :input, :kind, :stream, :task_id, :metadata, :inserted_at]
end

defmodule SpectreMnemonic.Stream do
  @moduledoc "A named activity lane, such as `:chat`, `:research`, or a task-specific stream."
  defstruct [:id, :name, :task_id, status: :active, metadata: %{}, inserted_at: nil]
end

defmodule SpectreMnemonic.Moment do
  @moduledoc "An active memory item derived from a signal and kept in focus."
  defstruct [
    :id,
    :signal_id,
    :stream,
    :task_id,
    :kind,
    :text,
    :input,
    :vector,
    :binary_signature,
    :embedding,
    :fingerprint,
    :inserted_at,
    keywords: [],
    entities: [],
    attention: 1.0,
    metadata: %{}
  ]
end

defmodule SpectreMnemonic.Association do
  @moduledoc "A typed relationship between two memory records."
  defstruct [:id, :source_id, :relation, :target_id, weight: 1.0, metadata: %{}, inserted_at: nil]
end

defmodule SpectreMnemonic.Episode do
  @moduledoc "A consolidated sequence of related moments."
  defstruct [:id, :title, moment_ids: [], summary: nil, metadata: %{}, inserted_at: nil]
end

defmodule SpectreMnemonic.Knowledge do
  @moduledoc "A durable memory distilled from active focus."
  defstruct [
    :id,
    :source_id,
    :text,
    :vector,
    :binary_signature,
    :embedding,
    metadata: %{},
    inserted_at: nil
  ]
end

defmodule SpectreMnemonic.Skill do
  @moduledoc "A reusable procedure or learned behavior."
  defstruct [:id, :name, :steps, metadata: %{}, inserted_at: nil]
end

defmodule SpectreMnemonic.Cue do
  @moduledoc "The normalized query used by recall."
  defstruct [
    :input,
    :text,
    keywords: [],
    entities: [],
    vector: nil,
    binary_signature: nil,
    embedding: nil,
    fingerprint: nil,
    opts: []
  ]
end

defmodule SpectreMnemonic.Artifact do
  @moduledoc "A file, path, binary, or external object remembered by reference."
  defstruct [:id, :source, :content_type, metadata: %{}, inserted_at: nil]
end

defmodule SpectreMnemonic.RecallPacket do
  @moduledoc "The neighborhood returned by `SpectreMnemonic.recall/2`."
  defstruct [
    :cue,
    active_status: [],
    moments: [],
    episodes: [],
    knowledge: [],
    artifacts: [],
    associations: [],
    confidence: 0.0
  ]
end

defmodule SpectreMnemonic.Focus do
  @moduledoc """
  GenServer that owns the active in-memory focus and writes important records to
  persistent memory.

  The struct exists as part of the core vocabulary; the process is the live
  owner of focus state.
  """

  use GenServer

  alias SpectreMnemonic.{Artifact, Association, Moment, PersistentMemory, Signal}
  alias SpectreMnemonic.Store.ETSOwner

  @default_attention 1.0
  defstruct active_moment_ids: [], metadata: %{}

  @doc "Starts the focus process."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Stores a signal and returns the created signal and moment."
  def record_signal(input, opts) do
    GenServer.call(__MODULE__, {:record_signal, input, opts})
  end

  @doc "Returns the current status for a stream or task id."
  def status(stream_or_task_id) do
    case :ets.lookup(:mnemonic_status, stream_or_task_id) do
      [{^stream_or_task_id, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  @doc "Creates a graph edge between two memory records."
  def link(source_id, relation, target_id, opts \\ []) do
    GenServer.call(__MODULE__, {:link, source_id, relation, target_id, opts})
  end

  @doc "Stores an artifact reference in ETS and on disk."
  def artifact(path_or_binary, opts \\ []) do
    GenServer.call(__MODULE__, {:artifact, path_or_binary, opts})
  end

  @doc "Forgets matching active memory records."
  def forget(selector, opts \\ []) do
    GenServer.call(__MODULE__, {:forget, selector, opts})
  end

  @doc "Returns all active moments. This is used by recall and simple consolidation."
  def moments do
    :ets.tab2list(:mnemonic_moments)
    |> Enum.map(fn {_id, moment} -> moment end)
  end

  @doc "Returns all active associations."
  def associations do
    :ets.tab2list(:mnemonic_associations)
    |> Enum.map(fn {_id, association} -> association end)
  end

  @doc "Returns active artifacts by id."
  def artifacts(ids) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case :ets.lookup(:mnemonic_artifacts, id) do
        [{^id, artifact}] -> [artifact]
        [] -> []
      end
    end)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:record_signal, input, opts}, _from, state) do
    now = DateTime.utc_now()
    stream = Keyword.get(opts, :stream) || :chat
    task_id = Keyword.get(opts, :task_id)
    kind = Keyword.get(opts, :kind, infer_kind(input, opts))
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    signal = %Signal{
      id: id("sig"),
      input: input,
      kind: kind,
      stream: stream,
      task_id: task_id,
      metadata: metadata,
      inserted_at: now
    }

    moment = build_moment(signal, opts, now)

    :ets.insert(:mnemonic_signals, {signal.id, signal})
    :ets.insert(:mnemonic_moments, {moment.id, moment})
    :ets.insert(:mnemonic_attention, {moment.id, moment.attention})
    update_status(stream, task_id, input, kind, now)

    with {:ok, _} <- PersistentMemory.append(:signals, signal),
         {:ok, _} <- PersistentMemory.append(:moments, moment) do
      SpectreMnemonic.Recall.Index.upsert(moment)
      {:reply, {:ok, %{signal: signal, moment: moment}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:link, source_id, relation, target_id, opts}, _from, state) do
    if memory_id?(source_id) and memory_id?(target_id) do
      association = %Association{
        id: id("assoc"),
        source_id: source_id,
        relation: relation,
        target_id: target_id,
        weight: Keyword.get(opts, :weight, 1.0),
        metadata: Map.new(Keyword.get(opts, :metadata, %{})),
        inserted_at: DateTime.utc_now()
      }

      :ets.insert(:mnemonic_associations, {association.id, association})

      case PersistentMemory.append(:associations, association) do
        {:ok, _} -> {:reply, {:ok, association}, state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :unknown_memory_id}, state}
    end
  end

  def handle_call({:artifact, path_or_binary, opts}, _from, state) do
    artifact = %Artifact{
      id: id("art"),
      source: artifact_source(path_or_binary),
      content_type: Keyword.get(opts, :content_type),
      metadata: Map.new(Keyword.get(opts, :metadata, %{})),
      inserted_at: DateTime.utc_now()
    }

    :ets.insert(:mnemonic_artifacts, {artifact.id, artifact})

    case PersistentMemory.append(:artifacts, artifact) do
      {:ok, _} -> {:reply, {:ok, artifact}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:forget, selector, _opts}, _from, state) do
    forget_ids =
      moments()
      |> Enum.filter(&selected?(&1, selector))
      |> Enum.map(& &1.id)

    Enum.each(forget_ids, fn id ->
      :ets.delete(:mnemonic_moments, id)
      :ets.delete(:mnemonic_attention, id)
      SpectreMnemonic.Recall.Index.delete(id)

      PersistentMemory.append(:tombstones, %{
        family: :moments,
        id: id,
        forgotten_at: DateTime.utc_now()
      })
    end)

    {:reply, {:ok, length(forget_ids)}, state}
  end

  defp build_moment(signal, opts, now) do
    embedding = SpectreMnemonic.Embedding.embed(signal.input, opts)

    %Moment{
      id: id("mom"),
      signal_id: signal.id,
      stream: signal.stream,
      task_id: signal.task_id,
      kind: signal.kind,
      text: to_text(signal.input),
      input: signal.input,
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      keywords: keywords(signal.input),
      entities: entities(signal.input),
      fingerprint: fingerprint(signal.input),
      attention: Keyword.get(opts, :attention, @default_attention),
      metadata: signal.metadata,
      inserted_at: now
    }
  end

  defp update_status(stream, task_id, input, kind, now) do
    status = %{stream: stream, task_id: task_id, kind: kind, last_input: input, updated_at: now}
    :ets.insert(:mnemonic_status, {stream, status})
    if task_id, do: :ets.insert(:mnemonic_status, {task_id, status})
  end

  defp infer_kind(input, _opts) when is_binary(input), do: :text
  defp infer_kind(%{kind: kind}, _opts), do: kind
  defp infer_kind(_input, _opts), do: :event

  defp memory_id?(id) do
    ETSOwner.member?(:mnemonic_moments, id) or ETSOwner.member?(:mnemonic_signals, id) or
      ETSOwner.member?(:mnemonic_artifacts, id)
  end

  defp selected?(moment, id) when is_binary(id), do: moment.id == id or moment.signal_id == id
  defp selected?(moment, {:stream, stream}), do: moment.stream == stream
  defp selected?(moment, {:task, task_id}), do: moment.task_id == task_id
  defp selected?(moment, fun) when is_function(fun, 1), do: fun.(moment)
  defp selected?(_moment, _selector), do: false

  defp artifact_source(binary) when is_binary(binary), do: binary
  defp artifact_source(term), do: term

  defp to_text(input) when is_binary(input), do: input
  defp to_text(input), do: inspect(input)

  defp keywords(input) do
    input
    |> to_text()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  defp entities(input) do
    Regex.scan(~r/\b[A-Z][A-Za-z0-9_]+\b/, to_text(input))
    |> List.flatten()
    |> Enum.uniq()
  end

  defp fingerprint(input) do
    SpectreMnemonic.Fingerprint.build(input)
  end

  defp id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end
end
