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
  """
  def signal(input, opts \\ []) do
    SpectreMnemonic.Router.signal(input, opts)
  end

  @doc """
  Recalls nearby active memory for a cue.

  The first implementation searches active ETS records with keyword, entity,
  hamming, vector, and graph hints when available.
  """
  def recall(cue, opts \\ []) do
    SpectreMnemonic.Recall.recall(cue, opts)
  end

  @doc """
  Searches active memory and durable stores.

  Active results come from recall and durable results come from stores that
  advertise `:search`, `:vector_search`, or `:fulltext_search`.
  """
  def search(cue, opts \\ []) do
    with {:ok, packet} <- recall(cue, opts),
         {:ok, durable_results} <- SpectreMnemonic.PersistentMemory.search(cue, opts) do
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
  Returns status for a stream name or task id.
  """
  def status(stream_or_task_id) do
    SpectreMnemonic.Focus.status(stream_or_task_id)
  end

  @doc """
  Writes important active memory to disk.

  V1 keeps consolidation deliberately simple: selected moments are appended as
  `:knowledge` records, and a consolidation job record marks the run.
  """
  def consolidate(opts \\ []) do
    SpectreMnemonic.Consolidator.consolidate(opts)
  end

  @doc """
  Creates an association between two memory ids.
  """
  def link(source_id, relation, target_id, opts \\ []) do
    SpectreMnemonic.Focus.link(source_id, relation, target_id, opts)
  end

  @doc """
  Stores an artifact reference or binary payload.
  """
  def artifact(path_or_binary, opts \\ []) do
    SpectreMnemonic.Focus.artifact(path_or_binary, opts)
  end

  @doc """
  Forgets matching records from active memory.

  Supported selectors are ids, `{:stream, stream}`, `{:task, task_id}`, and
  predicate functions that receive a moment.
  """
  def forget(selector, opts \\ []) do
    SpectreMnemonic.Focus.forget(selector, opts)
  end
end
