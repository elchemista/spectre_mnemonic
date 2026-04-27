defmodule SpectreMnemonic do
  @moduledoc """
  Public facade for the Spectre Mnemonic memory engine.

  This module is the API users should call. Implementation details live under
  `SpectreMnemonic.*` so the outside surface can stay small and stable.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  @doc """
  Records a new signal and routes it into a stream.

  `input` can be text, a map, or any Erlang term. Options may include:

    * `:stream` - explicit stream name
    * `:task_id` - task identifier used for status and routing
    * `:kind` - signal kind, such as `:chat`, `:research`, or `:tool`
    * `:metadata` - extra context stored with the signal
    * `:action_recipe` - English-like Action Language text or map stored as data
  """
  @spec signal(input :: term(), opts :: keyword()) ::
          {:ok, SpectreMnemonic.Active.Focus.record_result()}
          | {:error, term()}
  def signal(input, opts \\ []) do
    SpectreMnemonic.Active.Router.signal(input, opts)
  end

  @doc """
  Remembers any already-parsed information through the unified intake layer.

  `remember/2` accepts text, prompts, chat, tasks, code strings, maps, lists, and
  JSON-looking strings as plain text. It builds active memory, summaries,
  categories, and graph links. Durable promotion is handled by consolidation
  unless `persist?: true` is passed.
  """
  @spec remember(input :: term(), opts :: keyword()) ::
          {:ok, SpectreMnemonic.Intake.Packet.t()} | {:error, term()}
  def remember(input, opts \\ []) do
    SpectreMnemonic.Intake.remember(input, opts)
  end

  @doc """
  Recalls nearby active memory for a cue.

  The first implementation searches active ETS records with keyword, entity,
  hamming, vector, and graph hints when available.
  """
  @spec recall(cue :: term(), opts :: keyword()) ::
          {:ok, SpectreMnemonic.Recall.Packet.t()} | {:error, term()}
  def recall(cue, opts \\ []) do
    SpectreMnemonic.Recall.Engine.recall(cue, opts)
  end

  @doc """
  Searches active memory and durable stores.

  Active results come from recall and durable results come from stores that
  advertise `:search`, `:vector_search`, or `:fulltext_search`.
  """
  @spec search(cue :: term(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(cue, opts \\ []) do
    with {:ok, packet} <- recall(cue, opts),
         {:ok, durable_results} <- SpectreMnemonic.Persistence.Manager.search(cue, opts) do
      active_results =
        packet.moments
        |> Enum.with_index()
        |> Enum.map(fn {moment, index} ->
          %{
            source: :active,
            family: :moments,
            id: moment.id,
            rank: index + 1,
            record: moment
          }
        end)

      durable_results =
        Enum.map(durable_results, fn result ->
          result
          |> Map.new()
          |> Map.put_new(:source, :persistent)
        end)

      {:ok, active_results ++ durable_results}
    end
  end

  @doc """
  Loads compact progressive knowledge from `knowledge.smem`.

  The loader is budgeted: it returns a compact `%SpectreMnemonic.Knowledge.Record{}`
  packet instead of hydrating the whole event log into active ETS memory.
  """
  @spec knowledge(keyword()) :: {:ok, SpectreMnemonic.Knowledge.Record.t()}
  def knowledge(opts \\ []) do
    SpectreMnemonic.Knowledge.Base.load(opts)
  end

  @doc """
  Alias for `knowledge/1`.
  """
  @spec load_knowledge(keyword()) :: {:ok, SpectreMnemonic.Knowledge.Record.t()}
  def load_knowledge(opts \\ []) do
    knowledge(opts)
  end

  @doc """
  Searches compact progressive knowledge in `knowledge.smem`.

  This is a targeted read path: it returns scored event matches and does not
  hydrate the full event log into active ETS memory.
  """
  @spec search_knowledge(cue :: term(), opts :: keyword()) :: {:ok, [map()]}
  def search_knowledge(cue, opts \\ []) do
    SpectreMnemonic.Knowledge.Base.search(cue, opts)
  end

  @doc """
  Compacts active memory and existing `knowledge.smem` events.

  Applications can configure `:compact_adapter` or pass one in opts to use an
  LLM or custom strategy. Without an adapter, a deterministic compact strategy
  writes a concise event set.
  """
  @spec compact_knowledge(keyword()) ::
          {:ok, %{events: [map()], count: non_neg_integer()}} | {:error, term()}
  def compact_knowledge(opts \\ []) do
    SpectreMnemonic.Knowledge.Compact.compact_knowledge(opts)
  end

  @doc """
  Returns status for a stream name or task id.
  """
  @spec status(stream_or_task_id :: term()) :: {:ok, map()} | {:error, :not_found}
  def status(stream_or_task_id) do
    SpectreMnemonic.Active.Focus.status(stream_or_task_id)
  end

  @doc """
  Writes important active memory to disk.

  V1 keeps consolidation deliberately simple: selected moments are appended as
  `:knowledge` records, and a consolidation job record marks the run.
  """
  @spec consolidate(opts :: keyword()) ::
          {:ok, [SpectreMnemonic.Knowledge.Record.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    SpectreMnemonic.Knowledge.Consolidator.consolidate(opts)
  end

  @doc """
  Creates an association between two memory ids.
  """
  @spec link(binary(), atom(), binary(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Association.t()} | {:error, term()}
  def link(source_id, relation, target_id, opts \\ []) do
    SpectreMnemonic.Active.Focus.link(source_id, relation, target_id, opts)
  end

  @doc """
  Stores an artifact reference or binary payload.

  Pass `:action_recipe` to attach inert Action Language data to the artifact.
  """
  @spec artifact(path_or_binary :: term(), opts :: keyword()) ::
          {:ok,
           SpectreMnemonic.Memory.Artifact.t()
           | %{
               artifact: SpectreMnemonic.Memory.Artifact.t(),
               action_recipe: SpectreMnemonic.Memory.ActionRecipe.t()
             }}
          | {:error, term()}
  def artifact(path_or_binary, opts \\ []) do
    SpectreMnemonic.Active.Focus.artifact(path_or_binary, opts)
  end

  @doc """
  Forgets matching records from active memory.

  Supported selectors are ids, `{:stream, stream}`, `{:task, task_id}`, and
  predicate functions that receive a moment.
  """
  @spec forget(SpectreMnemonic.Active.Focus.selector(), keyword()) :: {:ok, non_neg_integer()}
  def forget(selector, opts \\ []) do
    SpectreMnemonic.Active.Focus.forget(selector, opts)
  end
end
