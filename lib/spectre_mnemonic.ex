defmodule SpectreMnemonic do
  @moduledoc """
  Public facade for the Spectre Mnemonic memory engine.

  This module is the API users should call. Implementation details live under
  `SpectreMnemonic.*` so the outside surface can stay small and stable.

  Spectre Mnemonic is not a database of everything.
  Spectre Mnemonic is a living focus that slowly becomes organized memory.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Active.Router
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Intake
  alias SpectreMnemonic.Knowledge.Base
  alias SpectreMnemonic.Knowledge.Compact
  alias SpectreMnemonic.Knowledge.Consolidator
  alias SpectreMnemonic.Knowledge.Learning
  alias SpectreMnemonic.Knowledge.Record
  alias SpectreMnemonic.Memory.ActionRecipe
  alias SpectreMnemonic.Memory.Artifact
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.MentalModels
  alias SpectreMnemonic.Observations
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Recall.Engine
  alias SpectreMnemonic.Recall.Packet
  alias SpectreMnemonic.Reflection
  alias SpectreMnemonic.Secrets

  @doc """
  Records a new signal and routes it into a stream.

  Use `signal/2` for small, immediate pieces of working memory: a chat turn,
  tool result, user preference, task status, or any event that should become
  searchable right away. The router chooses a stream, stores the raw signal, and
  creates a moment that recall can rank later.

  `input` can be text, a map, or any Erlang term. Common options:

    * `:stream` - explicit stream name
    * `:task_id` - task identifier used for status and routing
    * `:kind` - signal kind, such as `:chat`, `:research`, or `:tool`
    * `:metadata` - extra context stored with the signal
    * `:action_recipe` - English-like Action Language text or map stored as data

  ## Examples

      iex> SpectreMnemonic.signal("User prefers compact summaries", stream: :chat)
      {:ok, %{signal: %SpectreMnemonic.Memory.Signal{}, moment: %SpectreMnemonic.Memory.Moment{}}}

      iex> SpectreMnemonic.signal("Deploy finished", task_id: "deploy-42", kind: :tool)
      {:ok, %{signal: _signal, moment: moment}}
      iex> moment.task_id
      "deploy-42"
  """
  @spec signal(input :: term(), opts :: keyword()) ::
          {:ok, Focus.record_result()}
          | {:error, term()}
  def signal(input, opts \\ []) do
    Router.signal(input, opts)
  end

  @doc """
  Remembers any already-parsed information through the unified intake layer.

  Use `remember/2` when the input deserves richer structure than one signal. It
  accepts text, prompts, chat, tasks, code strings, maps, lists, and JSON-looking
  strings as plain text. Intake builds a root moment, optional chunks, summaries,
  categories, entity timeline nodes, graph links, and a return packet describing
  what was created.

  Entity timeline extraction is on by default for public memory. Pass
  `extract_entities?: false` to skip it, `entity_extraction_adapter: MyAdapter`
  to add model-backed extraction, or `sensitive_numbers: :raw | :skip` to
  change the default classified/redacted handling for phone-like numbers.

  Durable promotion is intentionally separate: use `persist?: true` for an
  immediate durable write, or let `consolidate/1` promote important active memory
  later.

  ## Examples

      iex> {:ok, packet} = SpectreMnemonic.remember("Ana owns the Stripe rollout task")
      iex> packet.root.kind
      :text

      iex> SpectreMnemonic.remember(
      ...>   %{title: "Fix flaky CI", text: "Retry only transient download failures"},
      ...>   kind: :task,
      ...>   task_id: "ci-17",
      ...>   tags: [:ci, :reliability]
      ...> )
      {:ok, %SpectreMnemonic.Intake.Packet{}}
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

  Recall returns a `%SpectreMnemonic.Recall.Packet{}` rather than a final prose
  answer. That keeps the library useful for agents, tools, and applications that
  want to inspect sources, actions, observations, and mental models separately.

  ## Examples

      iex> SpectreMnemonic.signal("The migration task is blocked by missing credentials")
      iex> {:ok, packet} = SpectreMnemonic.recall("why is the migration blocked?")
      iex> Enum.map(packet.moments, & &1.text)
      ["The migration task is blocked by missing credentials"]
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

  This function is deliberately explicit. Recall can return locked secret
  placeholders, but plaintext is only recovered when the configured authorization
  adapter approves the reveal request.

  ## Example

      iex> {:ok, secret} = SpectreMnemonic.reveal(locked_secret, actor: "operator")
      iex> secret.locked?
      false
  """
  @spec reveal(Secret.t(), keyword()) :: {:ok, Secret.t()} | {:error, term()}
  def reveal(secret, opts \\ []) do
    Secrets.reveal(secret, opts)
  end

  @doc """
  Searches active memory and durable stores.

  Active results come from recall and durable results come from stores that
  advertise `:search`, `:vector_search`, or `:fulltext_search`.

  Use `search/2` when you want a flat list of results across hot memory and
  durable memory. Use `recall/2` when you want the richer active-memory packet.

  ## Example

      iex> {:ok, results} = SpectreMnemonic.search("deployment checklist", limit: 5)
      iex> Enum.all?(results, &Map.has_key?(&1, :source))
      true
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

  ## Example

      iex> {:ok, observations} = SpectreMnemonic.consolidate_observations()
      iex> Enum.all?(observations, &match?(%SpectreMnemonic.Memory.Observation{}, &1))
      true
  """
  @spec consolidate_observations(keyword()) ::
          {:ok, [SpectreMnemonic.Memory.Observation.t()]} | {:error, term()}
  def consolidate_observations(opts \\ []) do
    Observations.consolidate(opts)
  end

  @doc """
  Searches consolidated observations.

  Observations are useful for questions such as "what does the system currently
  believe about this project?" because each result carries source ids,
  confidence, proof counts, and contradiction counts.

  ## Example

      iex> SpectreMnemonic.search_observations("release risk", limit: 3)
      {:ok, _observations}
  """
  @spec search_observations(term(), keyword()) ::
          {:ok, [SpectreMnemonic.Memory.Observation.t() | map()]}
  def search_observations(cue, opts \\ []) do
    Observations.search(cue, opts)
  end

  @doc """
  Verifies an observation with optional supporting or weakening evidence.

  Pass `:relation` as `:supports`, `:weakens`, or `:contradicts`. The observation
  keeps the evidence trail and recomputes state from proof and contradiction
  counts.

  ## Example

      iex> SpectreMnemonic.verify_observation(observation, relation: :supports, source_id: "mom_1")
      {:ok, %SpectreMnemonic.Memory.Observation{}}
  """
  @spec verify_observation(binary() | SpectreMnemonic.Memory.Observation.t(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.Observation.t()} | {:error, term()}
  def verify_observation(observation_or_id, opts \\ []) do
    Observations.verify(observation_or_id, opts)
  end

  @doc """
  Stores a curated mental model for stable recurring memory queries.

  Mental models are durable, reusable reasoning aids. They are separate from raw
  moments so an application can pin stable strategy, preference, or domain
  knowledge without relying on recency.

  ## Example

      iex> SpectreMnemonic.put_mental_model(%{
      ...>   name: "Incident review",
      ...>   statement: "Always separate detection, mitigation, and prevention."
      ...> })
      {:ok, %SpectreMnemonic.Memory.MentalModel{}}
  """
  @spec put_mental_model(term(), keyword()) ::
          {:ok, SpectreMnemonic.Memory.MentalModel.t()} | {:error, term()}
  def put_mental_model(input, opts \\ []) do
    MentalModels.put(input, opts)
  end

  @doc """
  Searches curated mental models.

  ## Example

      iex> SpectreMnemonic.search_mental_models("incident prevention")
      {:ok, _models}
  """
  @spec search_mental_models(term(), keyword()) ::
          {:ok, [SpectreMnemonic.Memory.MentalModel.t() | map()]}
  def search_mental_models(cue, opts \\ []) do
    MentalModels.search(cue, opts)
  end

  @doc """
  Reflects over memory without requiring an LLM.

  The default returns a structured evidence packet ordered as mental models,
  ranked observations, then raw recall. Observation evidence is ranked as
  decisions, preferences, project state, patterns, then facts. Pass `:adapter`
  or configure `:reflection_adapter` to turn that packet into a final response.

  `:max_tokens` is forwarded to recall as a best-effort packet budget. Recall
  may include one oversized primary evidence item when excluding it would make
  the packet empty.

  Use reflection when a caller wants a prepared evidence bundle or when a custom
  adapter should transform memory into a natural-language answer.

  ## Example

      iex> {:ok, reflection} = SpectreMnemonic.reflect("What should I remember about billing?")
      iex> reflection.query
      "What should I remember about billing?"
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

  ## Example

      iex> {:ok, knowledge} = SpectreMnemonic.knowledge()
      iex> knowledge.skills
      []
  """
  @spec knowledge(keyword()) :: {:ok, Record.t()}
  def knowledge(opts \\ []) do
    Base.load(opts)
  end

  @doc """
  Alias for `knowledge/1`.

  ## Example

      iex> SpectreMnemonic.load_knowledge()
      {:ok, %SpectreMnemonic.Knowledge.Record{}}
  """
  @spec load_knowledge(keyword()) :: {:ok, Record.t()}
  def load_knowledge(opts \\ []) do
    knowledge(opts)
  end

  @doc """
  Searches compact progressive knowledge in `knowledge.smem`.

  This is a targeted read path: it returns scored event matches and does not
  hydrate the full event log into active ETS memory.

  ## Example

      iex> SpectreMnemonic.search_knowledge("retry policy", limit: 5)
      {:ok, _matches}
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

  ## Examples

      iex> SpectreMnemonic.learn("Debug CI\\n- Read failing job logs\\n- Re-run only failed jobs")
      {:ok, %{event: %{type: :skill}, seq: _seq}}

      iex> SpectreMnemonic.learn(%{name: "Triage bug", steps: ["reproduce", "minimize", "fix"]})
      {:ok, %{event: _event, seq: _seq}}
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

  ## Example

      iex> SpectreMnemonic.compact_knowledge(limit: 50)
      {:ok, %{events: _events, count: _count}}
  """
  @spec compact_knowledge(keyword()) ::
          {:ok, %{events: [map()], count: non_neg_integer()}} | {:error, term()}
  def compact_knowledge(opts \\ []) do
    Compact.compact_knowledge(opts)
  end

  @doc """
  Returns status for a stream name or task id.

  ## Example

      iex> SpectreMnemonic.signal("Working on search", task_id: "search-1")
      iex> SpectreMnemonic.status("search-1")
      {:ok, %{status: :active}}
  """
  @spec status(stream_or_task_id :: term()) :: {:ok, map()} | {:error, :not_found}
  def status(stream_or_task_id) do
    Focus.status(stream_or_task_id)
  end

  @doc """
  Writes important active memory to disk.

  V1 keeps consolidation deliberately simple: selected moments are appended as
  `:knowledge` records, and a consolidation job record marks the run.

  ## Example

      iex> SpectreMnemonic.consolidate(min_attention: 0.5)
      {:ok, [%SpectreMnemonic.Knowledge.Record{} | _]}
  """
  @spec consolidate(opts :: keyword()) ::
          {:ok, [Record.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    Consolidator.consolidate(opts)
  end

  @doc """
  Creates an association between two memory ids.

  Links are graph edges between existing active records. Recall uses them to pull
  nearby moments, artifacts, and action recipes into the same packet.

  ## Example

      iex> SpectreMnemonic.link("mom_a", :supports, "mom_b")
      {:ok, %SpectreMnemonic.Memory.Association{}}
  """
  @spec link(binary(), atom(), binary(), keyword()) :: {:ok, Association.t()} | {:error, term()}
  def link(source_id, relation, target_id, opts \\ []) do
    Focus.link(source_id, relation, target_id, opts)
  end

  @doc """
  Stores an artifact reference or binary payload.

  Pass `:action_recipe` to attach inert Action Language data to the artifact.
  The recipe is stored as data only; it is never executed by the memory layer.

  ## Examples

      iex> SpectreMnemonic.artifact("/tmp/report.txt", kind: :file)
      {:ok, %SpectreMnemonic.Memory.Artifact{}}

      iex> SpectreMnemonic.artifact("raw bytes", action_recipe: "Open the report and summarize it")
      {:ok, %{artifact: %SpectreMnemonic.Memory.Artifact{}, action_recipe: %SpectreMnemonic.Memory.ActionRecipe{}}}
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

  Forgetting active memory also writes governance events so durable search can
  hide forgotten records by default.

  ## Examples

      iex> SpectreMnemonic.forget("mom_123")
      {:ok, 1}

      iex> SpectreMnemonic.forget({:task, "deploy-42"})
      {:ok, _count}
  """
  @spec forget(Focus.selector(), keyword()) :: {:ok, non_neg_integer()}
  def forget(selector, opts \\ []) do
    Focus.forget(selector, opts)
  end
end
