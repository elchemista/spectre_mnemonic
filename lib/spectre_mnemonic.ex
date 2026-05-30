defmodule SpectreMnemonic do
  @moduledoc """
  Public facade for the Spectre Mnemonic memory engine.

  This module is the API users should call. Implementation details live under
  `SpectreMnemonic.*` so the outside surface can stay small and stable.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  alias SpectreMnemonic.Active.{Focus, Router}
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Intake
  alias SpectreMnemonic.Knowledge.{Base, Compact, Consolidator, Learning, Record}
  alias SpectreMnemonic.MentalModels
  alias SpectreMnemonic.Memory.{ActionRecipe, Artifact, Association, Secret}
  alias SpectreMnemonic.Observations
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Reflection
  alias SpectreMnemonic.Recall.{Engine, Packet}
  alias SpectreMnemonic.Secrets

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
          {:ok, Focus.record_result()}
          | {:error, term()}
  def signal(input, opts \\ []) do
    Router.signal(input, opts)
  end

  @doc """
  Remembers any already-parsed information through the unified intake layer.

  `remember/2` accepts text, prompts, chat, tasks, code strings, maps, lists, and
  JSON-looking strings as plain text. It builds active memory, summaries,
  categories, entity timeline nodes, and graph links. Durable promotion is
  handled by consolidation unless `persist?: true` is passed.

  Entity timeline extraction is on by default for public memory. Pass
  `extract_entities?: false` to skip it, `entity_extraction_adapter: MyAdapter`
  to add model-backed extraction, or `sensitive_numbers: :raw | :skip` to
  change the default classified/redacted handling for phone-like numbers.
  """
  @spec remember(input :: term(), opts :: keyword()) ::
          {:ok, Intake.Packet.t()} | {:error, term()}
  def remember(input, opts \\ []) do
    Intake.remember(input, opts)
  end

  @doc """
  Recalls nearby active memory for a cue.

  The first implementation searches active ETS records with keyword, entity,
  hamming, vector, and graph hints when available.
  """
  @spec recall(cue :: term(), opts :: keyword()) ::
          {:ok, Packet.t()} | {:error, term()}
  def recall(cue, opts \\ []) do
    Engine.recall(cue, opts)
  end

  @doc """
  Reveals a locked secret returned by recall.

  Applications provide authorization through `:authorization_adapter` or
  `:secret_authorization_adapter` config. The same `:secret_key`,
  `:secret_key_fun`, or custom crypto adapter used for storage must be available
  to decrypt the secret.
  """
  @spec reveal(Secret.t(), keyword()) :: {:ok, Secret.t()} | {:error, term()}
  def reveal(secret, opts \\ []) do
    Secrets.reveal(secret, opts)
  end

  @doc """
  Searches active memory and durable stores.

  Active results come from recall and durable results come from stores that
  advertise `:search`, `:vector_search`, or `:fulltext_search`.
  """
  @spec search(cue :: term(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(cue, opts \\ []) do
    with {:ok, packet} <- recall(cue, opts),
         {:ok, durable_results} <- Manager.search(cue, opts) do
      active_results =
        packet.moments
        |> Enum.filter(&Governance.search_visible?(&1.id, opts))
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
  Consolidates evidence-grounded observations from existing memory.

  Observations are derived beliefs with source evidence, confidence, trend, and
  lifecycle state. They are stored through the same append-only persistence
  manager used by the rest of the library.
  """
  @spec consolidate_observations(keyword()) ::
          {:ok, [SpectreMnemonic.Memory.Observation.t()]} | {:error, term()}
  def consolidate_observations(opts \\ []) do
    Observations.consolidate(opts)
  end

  @doc "Searches consolidated observations."
  @spec search_observations(term(), keyword()) ::
          {:ok, [SpectreMnemonic.Memory.Observation.t() | map()]}
  def search_observations(cue, opts \\ []) do
    Observations.search(cue, opts)
  end

  @doc "Verifies an observation with optional supporting or weakening evidence."
  @spec verify_observation(binary() | SpectreMnemonic.Memory.Observation.t(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Observation.t()} | {:error, term()}
  def verify_observation(observation_or_id, opts \\ []) do
    Observations.verify(observation_or_id, opts)
  end

  @doc "Stores a curated mental model for stable recurring memory queries."
  @spec put_mental_model(term(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.MentalModel.t()} | {:error, term()}
  def put_mental_model(input, opts \\ []) do
    MentalModels.put(input, opts)
  end

  @doc "Searches curated mental models."
  @spec search_mental_models(term(), keyword()) ::
          {:ok, [SpectreMnemonic.Memory.MentalModel.t() | map()]}
  def search_mental_models(cue, opts \\ []) do
    MentalModels.search(cue, opts)
  end

  @doc """
  Reflects over memory without requiring an LLM.

  The default returns a structured evidence packet ordered as mental models,
  observations, then raw recall. Pass `:adapter` or configure
  `:reflection_adapter` to turn that packet into a final response.
  """
  @spec reflect(term(), keyword()) ::
          {:ok, SpectreMnemonic.Reflection.Packet.t()} | {:error, term()}
  def reflect(query, opts \\ []) do
    Reflection.reflect(query, opts)
  end

  @doc """
  Loads compact progressive knowledge from `knowledge.smem`.

  The loader is budgeted: it returns a compact `%SpectreMnemonic.Knowledge.Record{}`
  packet instead of hydrating the whole event log into active ETS memory.
  """
  @spec knowledge(keyword()) :: {:ok, Record.t()}
  def knowledge(opts \\ []) do
    Base.load(opts)
  end

  @doc """
  Alias for `knowledge/1`.
  """
  @spec load_knowledge(keyword()) :: {:ok, Record.t()}
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
    Base.search(cue, opts)
  end

  @doc """
  Learns a reusable skill directly into compact progressive knowledge.

  Text input is normalized into a `:skill` event using the first non-empty line
  as the name and bullet or numbered lines as steps. Structured maps or keyword
  lists may provide `:name`, `:steps`, `:rules`, `:examples`, `:text`, and
  `:metadata`.
  """
  @spec learn(input :: term(), opts :: keyword()) ::
          {:ok, %{event: map(), seq: pos_integer()}} | {:error, term()}
  def learn(input, opts \\ []) do
    Learning.learn(input, opts)
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
    Compact.compact_knowledge(opts)
  end

  @doc """
  Returns status for a stream name or task id.
  """
  @spec status(stream_or_task_id :: term()) :: {:ok, map()} | {:error, :not_found}
  def status(stream_or_task_id) do
    Focus.status(stream_or_task_id)
  end

  @doc """
  Writes important active memory to disk.

  V1 keeps consolidation deliberately simple: selected moments are appended as
  `:knowledge` records, and a consolidation job record marks the run.
  """
  @spec consolidate(opts :: keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    Consolidator.consolidate(opts)
  end

  @doc """
  Creates an association between two memory ids.
  """
  @spec link(binary(), atom(), binary(), keyword()) :: {:ok, Association.t()} | {:error, term()}
  def link(source_id, relation, target_id, opts \\ []) do
    Focus.link(source_id, relation, target_id, opts)
  end

  @doc """
  Stores an artifact reference or binary payload.

  Pass `:action_recipe` to attach inert Action Language data to the artifact.
  """
  @spec artifact(path_or_binary :: term(), opts :: keyword()) ::
          {:ok,
           Artifact.t()
           | %{
               artifact: Artifact.t(),
               action_recipe: ActionRecipe.t()
             }}
          | {:error, term()}
  def artifact(path_or_binary, opts \\ []) do
    Focus.artifact(path_or_binary, opts)
  end

  @doc """
  Forgets matching records from active memory.

  Supported selectors are ids, `{:stream, stream}`, `{:task, task_id}`, and
  predicate functions that receive a moment.
  """
  @spec forget(Focus.selector(), keyword()) :: {:ok, non_neg_integer()}
  def forget(selector, opts \\ []) do
    Focus.forget(selector, opts)
  end
end
