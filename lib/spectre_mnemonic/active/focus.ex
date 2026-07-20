defmodule SpectreMnemonic.Active.Focus do
  @moduledoc """
  Owns active in-memory focus and writes important records to durable memory.

  Focus is the hot working set. It stores signals, moments, associations,
  artifacts, and task status in ETS so recall can stay fast while persistence is
  delegated to `SpectreMnemonic.Persistence.Manager`.
  """

  use GenServer

  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.ActionRecipe
  alias SpectreMnemonic.Memory.Artifact
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Memory.Signal
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Recall.Fingerprint
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Secrets

  @default_attention 1.0

  @type state :: map()
  @type selector ::
          binary()
          | {:stream, term()}
          | {:task, term()}
          | (Moment.t() | Secret.t() -> boolean())
  @type record_result :: %{
          required(:signal) => Signal.t(),
          required(:moment) => Moment.t() | Secret.t(),
          optional(:action_recipe) => ActionRecipe.t()
        }
  @type action_bundle :: %{recipe: ActionRecipe.t(), association: Association.t()} | nil

  defstruct active_moment_ids: [], metadata: %{}

  @doc "Starts the focus process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Stores a signal and returns the created signal and moment."
  @spec record_signal(input :: term(), opts :: keyword()) ::
          {:ok, record_result()} | {:error, term()}
  def record_signal(input, opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      GenServer.call(__MODULE__, {:record_signal, input, opts})
    end
  end

  @doc "Returns the current status for a stream or task id."
  @spec status(stream_or_task_id :: term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def status(stream_or_task_id, opts \\ []) do
    case Identity.fetch_namespace(opts) do
      {:ok, namespace} ->
        key = {{namespace, Keyword.get(opts, :scope)}, stream_or_task_id}

        case :ets.lookup(:mnemonic_status, key) do
          [{^key, status}] -> {:ok, status}
          [] -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Creates a graph edge between two memory records."
  @spec link(binary(), atom(), binary(), keyword()) ::
          {:ok, Association.t()} | {:error, :unknown_memory_id | term()}
  def link(source_id, relation, target_id, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      GenServer.call(__MODULE__, {:link, source_id, relation, target_id, opts})
    end
  end

  @doc "Stores an artifact reference in ETS and on disk."
  @spec artifact(path_or_binary :: term(), opts :: keyword()) ::
          {:ok, Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}}
          | {:error, term()}
  def artifact(path_or_binary, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      GenServer.call(__MODULE__, {:artifact, path_or_binary, opts})
    end
  end

  @doc "Forgets matching active memory records."
  @spec forget(selector(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget(selector, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      GenServer.call(__MODULE__, {:forget, selector, opts})
    end
  end

  @doc "Returns all active moments. Recall and consolidation use this read path."
  @spec moments(keyword()) :: [Moment.t() | Secret.t()]
  def moments(opts \\ []) do
    :ets.tab2list(:mnemonic_moments)
    |> Enum.map(fn {_id, moment} -> moment end)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc "Returns all active associations."
  @spec associations(keyword()) :: [Association.t()]
  def associations(opts \\ []) do
    :ets.tab2list(:mnemonic_associations)
    |> Enum.map(fn {_id, association} -> association end)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc false
  @spec fold_moments(term(), (Moment.t() | Secret.t(), term() -> term()), keyword()) :: term()
  def fold_moments(acc, fun, opts \\ []) when is_function(fun, 2) do
    namespace = Identity.namespace!(opts)

    :mnemonic_moments_by_scope
    |> indexed_ids({namespace, Scope.from_opts(opts)})
    |> moments_by_ids(opts)
    |> Enum.reduce(acc, fun)
  end

  @doc false
  @spec recent_moments(term(), term(), pos_integer(), keyword()) :: [Moment.t() | Secret.t()]
  def recent_moments(stream, task_id, limit, opts \\ []) do
    namespace = Identity.namespace!(opts)
    scope = Keyword.get(opts, :scope)
    stream_ids = indexed_ids(:mnemonic_moments_by_stream, {{namespace, scope}, stream})

    task_ids =
      if is_nil(task_id) do
        []
      else
        indexed_ids(:mnemonic_moments_by_task, {{namespace, scope}, task_id})
      end

    (stream_ids ++ task_ids)
    |> moments_by_ids(opts)
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond), :desc)
    |> Enum.take(limit)
  end

  @doc false
  @spec moments_by_ids([binary()] | MapSet.t(binary()), keyword()) ::
          [Moment.t() | Secret.t()]
  def moments_by_ids(ids, opts \\ []) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_moment/1)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc false
  @spec associations_for_ids([binary()] | MapSet.t(binary()), keyword()) :: [Association.t()]
  def associations_for_ids(ids, opts \\ []) do
    ids = ids |> Enum.uniq() |> MapSet.new()
    namespace = Identity.namespace!(opts)

    association_ids =
      for id <- ids,
          association_id <-
            indexed_ids(
              :mnemonic_associations_by_memory,
              {{namespace, Scope.from_opts(opts)}, id}
            ),
          do: association_id

    association_ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_association/1)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc "Returns active artifacts by id."
  @spec artifacts([binary()], keyword()) :: [Artifact.t()]
  def artifacts(ids, opts \\ []) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_artifact/1)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc "Returns active action recipes by id."
  @spec action_recipes([binary()], keyword()) :: [ActionRecipe.t()]
  def action_recipes(ids, opts \\ []) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_action_recipe/1)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @impl GenServer
  @spec init(state()) :: {:ok, state()}
  def init(state), do: {:ok, state}

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()}
  def handle_call({:record_signal, input, opts}, _from, state) do
    if Keyword.get(opts, :secret?, false) do
      {:reply, record_secret_signal(input, opts), state}
    else
      {:reply, record_plain_signal(input, opts), state}
    end
  end

  def handle_call({:link, source_id, relation, target_id, opts}, _from, state) do
    case association_context(source_id, target_id, opts) do
      {:ok, association_opts} ->
        association = build_association(source_id, relation, target_id, association_opts)

        case maybe_persist_value(:associations, association, association_opts) do
          {:ok, _association} = result ->
            insert_association(association)
            {:reply, result, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:artifact, path_or_binary, opts}, _from, state) do
    artifact = build_artifact(path_or_binary, opts)

    result =
      with {:ok, artifact} <- persist_value(:artifacts, artifact, opts),
           {:ok, action_bundle} <-
             maybe_attach_action_recipe(artifact.id, opts, artifact.inserted_at) do
        :ets.insert(:mnemonic_artifacts, {artifact.id, artifact})
        insert_action_bundle(action_bundle)
        {:ok, artifact_result(artifact, action_recipe(action_bundle))}
      end

    {:reply, result, state}
  end

  def handle_call({:forget, selector, opts}, _from, state) do
    forget_ids = forget_ids(selector, opts)
    {:reply, forget_moments(forget_ids, opts), state}
  end

  @spec record_plain_signal(term(), keyword()) :: {:ok, record_result()} | {:error, term()}
  defp record_plain_signal(input, opts) do
    now = DateTime.utc_now()
    stream = Keyword.get(opts, :stream) || :chat
    task_id = Keyword.get(opts, :task_id)
    kind = Keyword.get(opts, :kind, infer_kind(input, opts))
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    signal = %Signal{
      id: Identity.generate("sig", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      input: input,
      kind: kind,
      stream: stream,
      task_id: task_id,
      metadata: Identity.put_context(metadata, opts),
      inserted_at: now
    }

    moment = build_moment(signal, opts, now)

    store_recorded_signal(signal, moment, opts, now)
  end

  @spec record_secret_signal(term(), keyword()) :: {:ok, record_result()} | {:error, term()}
  defp record_secret_signal(input, opts) do
    now = DateTime.utc_now()
    stream = Keyword.get(opts, :stream) || :secrets
    task_id = Keyword.get(opts, :task_id)
    kind = Keyword.get(opts, :kind, :secret)
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))
    label = secret_label(opts, metadata)
    plaintext = to_text(input)
    redacted = redacted_secret_text(label)
    metadata = secret_metadata(metadata, label)

    signal = %Signal{
      id: Identity.generate("sig", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      input: redacted,
      kind: kind,
      stream: stream,
      task_id: task_id,
      metadata: Identity.put_context(metadata, opts),
      inserted_at: now
    }

    with {:ok, moment} <- build_secret(signal, label, redacted, plaintext, opts, now) do
      store_recorded_signal(signal, moment, opts, now)
    end
  end

  @spec store_recorded_signal(Signal.t(), Moment.t() | Secret.t(), keyword(), DateTime.t()) ::
          {:ok, record_result()} | {:error, term()}
  defp store_recorded_signal(signal, moment, opts, now) do
    with {:ok, _signal_result} <- maybe_persist_value(:signals, signal, opts),
         {:ok, _moment_result} <- maybe_persist_value(:moments, moment, opts),
         :ok <- maybe_observe_moment(moment, opts),
         {:ok, action_bundle} <- maybe_attach_action_recipe(moment.id, opts, now) do
      # Durable writes are complete before any hot projection becomes visible.
      :ets.insert(:mnemonic_signals, {signal.id, signal})
      insert_moment(moment)
      :ets.insert(:mnemonic_attention, {moment.id, moment.attention})
      update_status(signal, now)
      insert_action_bundle(action_bundle)
      Index.upsert(moment)
      enforce_hot_bounds(moment, opts)
      {:ok, record_signal_result(signal, moment, action_recipe(action_bundle))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lookup_artifact(binary()) :: [Artifact.t()]
  defp lookup_artifact(id), do: lookup_one(:mnemonic_artifacts, id)

  @spec lookup_moment(binary()) :: [Moment.t() | Secret.t()]
  defp lookup_moment(id), do: lookup_one(:mnemonic_moments, id)

  @spec lookup_association(binary()) :: [Association.t()]
  defp lookup_association(id), do: lookup_one(:mnemonic_associations, id)

  @spec lookup_action_recipe(binary()) :: [ActionRecipe.t()]
  defp lookup_action_recipe(id), do: lookup_one(:mnemonic_action_recipes, id)

  @spec lookup_one(atom(), term()) :: [term()]
  defp lookup_one(table, id) do
    case :ets.lookup(table, id) do
      [{^id, value}] -> [value]
      [] -> []
    end
  end

  @spec build_moment(Signal.t(), keyword(), DateTime.t()) :: Moment.t()
  defp build_moment(signal, opts, now) do
    embedding = Service.embed(signal.input, opts)
    temporal = Temporal.from_opts(opts, now)
    scope = Keyword.get(opts, :scope)

    metadata =
      signal.metadata
      |> Map.put_new(:scope, scope)
      |> Temporal.put_metadata(temporal)

    %Moment{
      id: Identity.generate("mom", opts),
      namespace: Identity.namespace!(opts),
      signal_id: signal.id,
      stream: signal.stream,
      task_id: signal.task_id,
      scope: scope,
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
      occurred_at: temporal.occurred_at,
      observed_at: temporal.observed_at,
      last_verified_at: temporal.last_verified_at,
      valid_from: temporal.valid_from,
      valid_until: temporal.valid_until,
      metadata:
        Governance.with_provenance(metadata,
          source_ids: [signal.id],
          provider: :active_focus,
          confidence: Keyword.get(opts, :confidence, 1.0),
          occurred_at: temporal.occurred_at,
          observed_at: temporal.observed_at || now,
          last_verified_at: temporal.last_verified_at || now,
          valid_from: temporal.valid_from,
          valid_until: temporal.valid_until
        ),
      inserted_at: now
    }
  end

  @spec build_secret(Signal.t(), binary(), binary(), binary(), keyword(), DateTime.t()) ::
          {:ok, Secret.t()} | {:error, term()}
  defp build_secret(signal, label, redacted, plaintext, opts, now) do
    memory_id = Identity.generate("mom", opts)
    secret_id = Identity.generate("sec", opts)

    context = %{
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      memory_id: memory_id,
      signal_id: signal.id,
      secret_id: secret_id,
      label: label,
      metadata: signal.metadata
    }

    with {:ok, encrypted} <- Secrets.encrypt(plaintext, context, opts) do
      embedding = Service.embed(redacted, secret_embedding_opts(opts))
      temporal = Temporal.from_opts(opts, now)
      scope = Keyword.get(opts, :scope)

      metadata =
        signal.metadata
        |> Map.put_new(:scope, scope)
        |> Temporal.put_metadata(temporal)

      {:ok,
       %Secret{
         id: memory_id,
         namespace: Identity.namespace!(opts),
         signal_id: signal.id,
         secret_id: secret_id,
         label: label,
         stream: signal.stream,
         task_id: signal.task_id,
         scope: scope,
         kind: signal.kind,
         text: redacted,
         input: redacted,
         vector: embedding.vector,
         binary_signature: Map.get(embedding, :binary_signature),
         embedding: embedding,
         keywords: keywords(redacted),
         entities: entities(redacted),
         fingerprint: fingerprint(redacted),
         attention: Keyword.get(opts, :attention, @default_attention),
         occurred_at: temporal.occurred_at,
         observed_at: temporal.observed_at,
         last_verified_at: temporal.last_verified_at,
         valid_from: temporal.valid_from,
         valid_until: temporal.valid_until,
         locked?: true,
         revealed?: false,
         algorithm: Map.fetch!(encrypted, :algorithm),
         ciphertext: Map.fetch!(encrypted, :ciphertext),
         iv: Map.fetch!(encrypted, :iv),
         tag: Map.fetch!(encrypted, :tag),
         aad: Map.fetch!(encrypted, :aad),
         reveal: Secrets.reveal_instruction(),
         metadata:
           Governance.with_provenance(metadata,
             source_ids: [signal.id],
             provider: :active_focus,
             confidence: Keyword.get(opts, :confidence, 1.0),
             occurred_at: temporal.occurred_at,
             observed_at: temporal.observed_at || now,
             last_verified_at: temporal.last_verified_at || now,
             valid_from: temporal.valid_from,
             valid_until: temporal.valid_until
           ),
         inserted_at: now
       }}
    end
  end

  @spec build_association(binary(), atom(), binary(), keyword()) :: Association.t()
  defp build_association(source_id, relation, target_id, opts) do
    %Association{
      id: Identity.generate("assoc", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      source_id: source_id,
      relation: relation,
      target_id: target_id,
      weight: Keyword.get(opts, :weight, 1.0),
      metadata:
        opts
        |> Keyword.get(:metadata, %{})
        |> Map.new()
        |> Identity.put_context(opts),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec build_artifact(term(), keyword()) :: Artifact.t()
  defp build_artifact(path_or_binary, opts) do
    %Artifact{
      id: Identity.generate("art", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      source: artifact_source(path_or_binary),
      content_type: Keyword.get(opts, :content_type),
      metadata:
        opts
        |> Keyword.get(:metadata, %{})
        |> Map.new()
        |> Identity.put_context(opts),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec maybe_attach_action_recipe(binary(), keyword(), DateTime.t()) ::
          {:ok, action_bundle()} | {:error, term()}
  defp maybe_attach_action_recipe(memory_id, opts, now) do
    memory_id
    |> build_action_recipe(opts, now)
    |> attach_action_recipe(memory_id, opts)
  end

  @spec build_action_recipe(binary(), keyword(), DateTime.t()) :: ActionRecipe.t() | nil
  defp build_action_recipe(memory_id, opts, now) do
    opts
    |> Keyword.get(:action_recipe)
    |> action_recipe_from_option(memory_id, opts, now)
  end

  @spec action_recipe_from_option(term(), binary(), keyword(), DateTime.t()) ::
          ActionRecipe.t() | nil
  defp action_recipe_from_option(recipe, memory_id, opts, now)
       when is_binary(recipe) and recipe != "" do
    action_recipe_from_text(memory_id, recipe, opts, now)
  end

  defp action_recipe_from_option(recipe, memory_id, opts, now) when is_map(recipe) do
    action_recipe_from_map(recipe, memory_id, opts, now)
  end

  defp action_recipe_from_option(recipe, memory_id, opts, now) when is_list(recipe) do
    recipe
    |> Map.new()
    |> action_recipe_from_map(memory_id, opts, now)
  end

  defp action_recipe_from_option(_missing, _memory_id, _opts, _now), do: nil

  @spec attach_action_recipe(ActionRecipe.t() | nil, binary(), keyword()) ::
          {:ok, action_bundle()} | {:error, term()}
  defp attach_action_recipe(nil, _memory_id, _opts), do: {:ok, nil}

  defp attach_action_recipe(action_recipe, memory_id, opts) do
    with {:ok, _recipe_result} <- maybe_persist_value(:action_recipes, action_recipe, opts),
         {:ok, association} <-
           persist_attached_action(memory_id, action_recipe.id, action_recipe.inserted_at, opts) do
      {:ok, %{recipe: action_recipe, association: association}}
    end
  end

  @spec action_recipe_from_text(binary(), binary(), keyword(), DateTime.t()) :: ActionRecipe.t()
  defp action_recipe_from_text(memory_id, text, opts, now) do
    %ActionRecipe{
      id: Identity.generate("act", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      memory_id: memory_id,
      language: Keyword.get(opts, :action_language, :spectre_al),
      text: text,
      intent: Keyword.get(opts, :action_intent),
      status: Keyword.get(opts, :action_status, :stored),
      metadata: action_metadata(opts, %{}) |> Identity.put_context(opts),
      inserted_at: now
    }
  end

  @spec action_recipe_from_map(map(), binary(), keyword(), DateTime.t()) :: ActionRecipe.t()
  defp action_recipe_from_map(recipe, memory_id, opts, now) do
    metadata = recipe_value(recipe, :metadata, %{})

    %ActionRecipe{
      id: recipe_value(recipe, :id, Identity.generate("act", opts)),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      memory_id: recipe_value(recipe, :memory_id, memory_id),
      language: recipe_value(recipe, :language, :spectre_al),
      text: recipe_value(recipe, :text, ""),
      intent: recipe_value(recipe, :intent, Keyword.get(opts, :action_intent)),
      status: recipe_value(recipe, :status, :stored),
      metadata: action_metadata(opts, metadata) |> Identity.put_context(opts),
      inserted_at: recipe_value(recipe, :inserted_at, now)
    }
  end

  @spec recipe_value(map(), atom(), term()) :: term()
  defp recipe_value(recipe, key, default) do
    Map.get(recipe, key) || Map.get(recipe, Atom.to_string(key)) || default
  end

  @spec action_metadata(keyword(), map()) :: map()
  defp action_metadata(opts, recipe_metadata) do
    top_level =
      opts
      |> Keyword.take([:ttl_ms, :refresh_on_recall?, :source_url, :tags])
      |> Map.new()

    opts
    |> Keyword.get(:action_recipe_metadata, %{})
    |> Map.new()
    |> Map.merge(top_level)
    |> Map.merge(Map.new(recipe_metadata))
  end

  @spec persist_attached_action(binary(), binary(), DateTime.t(), keyword()) ::
          {:ok, Association.t()} | {:error, term()}
  defp persist_attached_action(memory_id, action_recipe_id, now, opts) do
    association = %Association{
      id: Identity.generate("assoc", opts),
      namespace: Identity.namespace!(opts),
      scope: Keyword.get(opts, :scope),
      source_id: memory_id,
      relation: :attached_action,
      target_id: action_recipe_id,
      weight: 1.0,
      metadata: Identity.put_context(%{language: :spectre_al}, opts),
      inserted_at: now
    }

    maybe_persist_value(:associations, association, opts)
  end

  @spec insert_action_bundle(action_bundle()) :: :ok
  defp insert_action_bundle(nil), do: :ok

  defp insert_action_bundle(%{recipe: recipe, association: association}) do
    :ets.insert(:mnemonic_action_recipes, {recipe.id, recipe})
    insert_association(association)
    :ok
  end

  @spec action_recipe(action_bundle()) :: ActionRecipe.t() | nil
  defp action_recipe(nil), do: nil
  defp action_recipe(%{recipe: recipe}), do: recipe

  @spec record_signal_result(Signal.t(), Moment.t() | Secret.t(), ActionRecipe.t() | nil) ::
          record_result()
  defp record_signal_result(signal, moment, nil), do: %{signal: signal, moment: moment}

  defp record_signal_result(signal, moment, action_recipe) do
    %{signal: signal, moment: moment, action_recipe: action_recipe}
  end

  @spec artifact_result(Artifact.t(), ActionRecipe.t() | nil) ::
          Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}
  defp artifact_result(artifact, nil), do: artifact

  defp artifact_result(artifact, action_recipe),
    do: %{artifact: artifact, action_recipe: action_recipe}

  @spec persist_value(atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp persist_value(family, value, opts) do
    case Manager.append(family, value, opts) do
      {:ok, _result} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_persist_value(atom(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp maybe_persist_value(family, value, opts) do
    if Keyword.get(opts, :persist?, true) do
      persist_value(family, value, opts)
    else
      {:ok, value}
    end
  end

  @spec maybe_observe_moment(Moment.t() | Secret.t(), keyword()) :: :ok | {:error, term()}
  defp maybe_observe_moment(moment, opts) do
    if Keyword.get(opts, :persist?, true) do
      Governance.observe_moment(moment, opts)
    else
      :ok
    end
  end

  @spec insert_moment(Moment.t() | Secret.t()) :: true
  defp insert_moment(moment) do
    partition = Scope.partition(moment)
    :ets.insert(:mnemonic_moments, {moment.id, moment})
    :ets.insert(:mnemonic_moments_by_stream, {{partition, moment.stream}, moment.id})

    if moment.task_id do
      :ets.insert(:mnemonic_moments_by_task, {{partition, moment.task_id}, moment.id})
    end

    :ets.insert(:mnemonic_moments_by_scope, {partition, moment.id})

    :ets.insert(:mnemonic_moments_by_signal, {moment.signal_id, moment.id})
  end

  @spec insert_association(Association.t()) :: true
  defp insert_association(association) do
    partition = Scope.partition(association)
    :ets.insert(:mnemonic_associations, {association.id, association})

    :ets.insert(
      :mnemonic_associations_by_memory,
      {{partition, association.source_id}, association.id}
    )

    :ets.insert(
      :mnemonic_associations_by_memory,
      {{partition, association.target_id}, association.id}
    )
  end

  @spec forget_moments([binary()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp forget_moments([], _opts), do: {:ok, 0}

  defp forget_moments(ids, opts) do
    moments = moments_by_ids(ids, opts)

    with {:ok, plan} <- forget_plan(moments, opts),
         :ok <- persist_forget_plan(plan, opts),
         :ok <- persist_forgotten_states(moments, opts) do
      apply_forget_plan(plan)
      {:ok, length(moments)}
    end
  end

  @spec forget_plan([Moment.t() | Secret.t()], keyword()) :: {:ok, map()} | {:error, term()}
  defp forget_plan(moments, opts) do
    moment_ids = moments |> Enum.map(& &1.id) |> MapSet.new()
    signal_ids = moments |> Enum.map(& &1.signal_id) |> MapSet.new()

    associations =
      moment_ids
      |> associations_for_ids(opts)

    association_ids = associations |> Enum.map(& &1.id) |> MapSet.new()

    recipe_ids =
      associations
      |> Enum.flat_map(fn association ->
        if association.relation == :attached_action and
             MapSet.member?(moment_ids, association.source_id) do
          [association.target_id]
        else
          []
        end
      end)
      |> MapSet.new()

    with {:ok, targets} <-
           durable_forget_targets(moment_ids, signal_ids, association_ids, recipe_ids, opts) do
      {:ok,
       %{
         moments: moments,
         moment_ids: moment_ids,
         signal_ids: signal_ids,
         associations: associations,
         association_ids: association_ids,
         recipe_ids: recipe_ids,
         durable_targets: targets
       }}
    end
  end

  @spec durable_forget_targets(MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t(), keyword()) ::
          {:ok, [{atom(), binary()}]} | {:error, term()}
  defp durable_forget_targets(moment_ids, signal_ids, association_ids, recipe_ids, opts) do
    explicit =
      Enum.concat([
        Enum.map(moment_ids, &{:moments, &1}),
        Enum.map(signal_ids, &{:signals, &1}),
        Enum.map(association_ids, &{:associations, &1}),
        Enum.map(recipe_ids, &{:action_recipes, &1})
      ])

    case Manager.replay(opts) do
      {:ok, records} ->
        ids = MapSet.union(moment_ids, signal_ids)

        referenced =
          records
          |> Enum.reject(&(&1.family in [:tombstones, :memory_states]))
          |> Enum.filter(&record_references?(&1.payload, ids))
          |> Enum.flat_map(fn record ->
            case payload_id(record.payload) do
              id when is_binary(id) -> [{record.family, id}]
              _missing -> []
            end
          end)

        {:ok, Enum.uniq(explicit ++ referenced)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec record_references?(term(), MapSet.t()) :: boolean()
  defp record_references?(payload, ids) when is_map(payload) do
    direct_ids =
      [:id, :source_id, :memory_id, :signal_id, :target_id]
      |> Enum.flat_map(&map_values(payload, &1))
      |> Enum.concat(
        payload
        |> map_values(:source_ids)
        |> Enum.flat_map(&List.wrap/1)
      )
      |> Enum.concat(provenance_source_ids(payload))

    Enum.any?(direct_ids, &MapSet.member?(ids, &1))
  end

  defp record_references?(_payload, _ids), do: false

  @spec provenance_source_ids(map()) :: [term()]
  defp provenance_source_ids(payload) do
    payload
    |> map_values(:metadata)
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&map_values(&1, :provenance))
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(&map_values(&1, :source_ids))
    |> Enum.flat_map(&List.wrap/1)
  end

  @spec map_values(map(), atom()) :: [term()]
  defp map_values(map, key) do
    string_key = Atom.to_string(key)

    []
    |> maybe_add_map_value(Map.has_key?(map, string_key), Map.get(map, string_key))
    |> maybe_add_map_value(Map.has_key?(map, key), Map.get(map, key))
  end

  @spec maybe_add_map_value([term()], boolean(), term()) :: [term()]
  defp maybe_add_map_value(values, true, value), do: [value | values]
  defp maybe_add_map_value(values, false, _value), do: values

  @spec persist_forget_plan(map(), keyword()) :: :ok | {:error, term()}
  defp persist_forget_plan(plan, opts) do
    now = DateTime.utc_now()

    Enum.reduce_while(plan.durable_targets, :ok, fn {family, id}, :ok ->
      payload = %{family: family, id: id, forgotten_at: now, reason: :explicit_forget}

      case Manager.append(:tombstones, payload, opts) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec persist_forgotten_states([Moment.t() | Secret.t()], keyword()) :: :ok | {:error, term()}
  defp persist_forgotten_states(moments, opts) do
    Enum.reduce_while(moments, :ok, fn moment, :ok ->
      event_opts = context_opts(moment, opts)

      case Governance.forget(moment.id, event_opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec apply_forget_plan(map()) :: :ok
  defp apply_forget_plan(plan) do
    Enum.each(plan.associations, &delete_association/1)
    Enum.each(plan.recipe_ids, &:ets.delete(:mnemonic_action_recipes, &1))
    Enum.each(plan.signal_ids, &:ets.delete(:mnemonic_signals, &1))
    Enum.each(plan.moments, &evict_hot_moment/1)
    delete_derived_hot_records(plan.moment_ids)
    :ok
  end

  @spec delete_derived_hot_records(MapSet.t()) :: :ok
  defp delete_derived_hot_records(moment_ids) do
    Enum.each([:mnemonic_observations, :mnemonic_mental_models], fn table ->
      table
      |> :ets.tab2list()
      |> Enum.each(&delete_referencing_record(&1, table, moment_ids))
    end)

    :ok
  end

  @spec delete_referencing_record({term(), map()}, atom(), MapSet.t()) :: true | nil
  defp delete_referencing_record({id, record}, table, moment_ids) do
    if record_references?(record, moment_ids), do: :ets.delete(table, id)
  end

  @spec delete_association(Association.t()) :: true
  defp delete_association(association) do
    partition = Scope.partition(association)
    :ets.delete(:mnemonic_associations, association.id)

    :ets.delete_object(
      :mnemonic_associations_by_memory,
      {{partition, association.source_id}, association.id}
    )

    :ets.delete_object(
      :mnemonic_associations_by_memory,
      {{partition, association.target_id}, association.id}
    )
  end

  @spec delete_moment_indexes(Moment.t() | Secret.t()) :: true
  defp delete_moment_indexes(moment) do
    partition = Scope.partition(moment)
    :ets.delete_object(:mnemonic_moments_by_stream, {{partition, moment.stream}, moment.id})

    if moment.task_id do
      :ets.delete_object(:mnemonic_moments_by_task, {{partition, moment.task_id}, moment.id})
    end

    :ets.delete_object(:mnemonic_moments_by_scope, {partition, moment.id})

    :ets.delete(:mnemonic_moments_by_signal, moment.signal_id)
  end

  @spec forget_ids(selector(), keyword()) :: [binary()]
  defp forget_ids({:stream, stream}, opts) do
    key = {{Identity.namespace!(opts), Keyword.get(opts, :scope)}, stream}
    indexed_ids(:mnemonic_moments_by_stream, key)
  end

  defp forget_ids({:task, task_id}, opts) do
    key = {{Identity.namespace!(opts), Keyword.get(opts, :scope)}, task_id}
    indexed_ids(:mnemonic_moments_by_task, key)
  end

  defp forget_ids(id, opts) when is_binary(id) do
    signal_ids = indexed_ids(:mnemonic_moments_by_signal, id)

    (direct_moment_ids(id) ++ signal_ids)
    |> Enum.uniq()
    |> moments_by_ids(opts)
    |> Enum.map(& &1.id)
  end

  defp forget_ids(selector, opts) do
    fold_moments(
      [],
      fn moment, ids ->
        if selected?(moment, selector),
          do: [moment.id | ids],
          else: ids
      end,
      opts
    )
  end

  @spec indexed_ids(atom(), term()) :: [binary()]
  defp indexed_ids(table, key) do
    table
    |> :ets.lookup(key)
    |> Enum.map(fn {_key, id} -> id end)
  end

  @spec direct_moment_ids(binary()) :: [binary()]
  defp direct_moment_ids(id) do
    case lookup_moment(id) do
      [_moment] -> [id]
      [] -> []
    end
  end

  @spec update_status(Signal.t(), DateTime.t()) :: true
  defp update_status(signal, now) do
    status = %{
      namespace: signal.namespace,
      scope: signal.scope,
      stream: signal.stream,
      task_id: signal.task_id,
      kind: signal.kind,
      status: :active,
      last_input: signal.input,
      updated_at: now
    }

    partition = {signal.namespace, signal.scope}
    :ets.insert(:mnemonic_status, {{partition, signal.stream}, status})
    if signal.task_id, do: :ets.insert(:mnemonic_status, {{partition, signal.task_id}, status})
  end

  @spec infer_kind(term(), keyword()) :: atom()
  defp infer_kind(input, _opts) when is_binary(input), do: :text
  defp infer_kind(%{kind: kind}, _opts), do: kind
  defp infer_kind(_input, _opts), do: :event

  @spec association_context(binary(), binary(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  defp association_context(source_id, target_id, opts) do
    with {:ok, source} <- memory_record(source_id),
         {:ok, target} <- memory_record(target_id),
         true <- Scope.partition(source) == Scope.partition(target),
         true <- Scope.match?(source, opts) and Scope.match?(target, opts) do
      {namespace, scope} = Scope.partition(source)

      {:ok,
       opts
       |> Keyword.put(:namespace, namespace)
       |> Keyword.put(:scope, scope)}
    else
      {:error, :not_found} -> {:error, :unknown_memory_id}
      false -> {:error, :cross_scope_association}
    end
  end

  @spec memory_record(binary()) :: {:ok, term()} | {:error, :not_found}
  defp memory_record(id) do
    [:mnemonic_moments, :mnemonic_signals, :mnemonic_artifacts, :mnemonic_action_recipes]
    |> Enum.find_value(fn table ->
      case lookup_one(table, id) do
        [record] -> {:ok, record}
        [] -> nil
      end
    end)
    |> case do
      nil -> {:error, :not_found}
      result -> result
    end
  end

  @spec enforce_hot_bounds(Moment.t() | Secret.t(), keyword()) :: :ok
  defp enforce_hot_bounds(moment, opts) do
    per_scope = hot_limit(opts, :max_moments_per_scope, 1_000)
    per_namespace = hot_limit(opts, :max_moments_per_namespace, 10_000)

    moment
    |> Scope.partition()
    |> then(&indexed_ids(:mnemonic_moments_by_scope, &1))
    |> moments_by_ids(context_opts(moment, opts))
    |> evict_excess(per_scope)

    namespace = Identity.namespace(moment)

    :mnemonic_moments
    |> :ets.tab2list()
    |> Enum.map(fn {_id, candidate} -> candidate end)
    |> Enum.filter(&(Identity.namespace(&1) == namespace))
    |> evict_excess(per_namespace)

    :ok
  end

  @spec hot_limit(keyword(), atom(), non_neg_integer()) :: non_neg_integer()
  defp hot_limit(opts, key, default) do
    configured =
      :spectre_mnemonic
      |> Application.get_env(:hot_memory, [])
      |> Map.new()

    case Keyword.get(opts, key, Map.get(configured, key, default)) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  @spec evict_excess([Moment.t() | Secret.t()], non_neg_integer()) :: :ok
  defp evict_excess(moments, limit) do
    moments
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at, :microsecond))
    |> Enum.take(max(length(moments) - limit, 0))
    |> Enum.each(&evict_hot_moment/1)

    :ok
  end

  @spec evict_hot_moment(Moment.t() | Secret.t()) :: :ok
  defp evict_hot_moment(moment) do
    associations = associations_for_ids([moment.id], context_opts(moment, []))

    recipe_ids =
      associations
      |> Enum.filter(&(&1.relation == :attached_action and &1.source_id == moment.id))
      |> Enum.map(& &1.target_id)

    Enum.each(associations, &delete_association/1)
    Enum.each(recipe_ids, &:ets.delete(:mnemonic_action_recipes, &1))
    delete_moment_indexes(moment)
    :ets.delete(:mnemonic_moments, moment.id)
    :ets.delete(:mnemonic_attention, moment.id)
    :ets.delete(:mnemonic_signals, moment.signal_id)
    refresh_status(moment)
    Index.delete(moment.id)
    :ok
  end

  @spec refresh_status(Moment.t() | Secret.t()) :: :ok
  defp refresh_status(moment) do
    partition = Scope.partition(moment)
    refresh_status_key(partition, moment.stream, :mnemonic_moments_by_stream)

    if moment.task_id do
      refresh_status_key(partition, moment.task_id, :mnemonic_moments_by_task)
    end

    :ok
  end

  @spec refresh_status_key(tuple(), term(), atom()) :: :ok
  defp refresh_status_key(partition, key, index_table) do
    :ets.delete(:mnemonic_status, {partition, key})
    {namespace, scope} = partition
    opts = [namespace: namespace, scope: scope]

    index_table
    |> indexed_ids({partition, key})
    |> moments_by_ids(opts)
    |> Enum.max_by(&DateTime.to_unix(&1.inserted_at, :microsecond), fn -> nil end)
    |> case do
      nil ->
        :ok

      latest ->
        status = %{
          namespace: namespace,
          scope: scope,
          stream: latest.stream,
          task_id: latest.task_id,
          kind: latest.kind,
          status: :active,
          last_input: latest.input,
          updated_at: latest.inserted_at
        }

        :ets.insert(:mnemonic_status, {{partition, key}, status})
        :ok
    end
  end

  @spec context_opts(term(), keyword()) :: keyword()
  defp context_opts(memory, opts) do
    opts
    |> Keyword.put(:namespace, Identity.namespace(memory) || Identity.namespace!(opts))
    |> Keyword.put(:scope, Scope.scope(memory))
  end

  @spec payload_id(term()) :: term()
  defp payload_id(payload) when is_map(payload) do
    payload
    |> map_values(:id)
    |> Enum.find_value(fn
      id when is_binary(id) -> id
      id when is_atom(id) -> Atom.to_string(id)
      _other -> nil
    end)
  end

  defp payload_id(_payload), do: nil

  @spec selected?(Moment.t() | Secret.t(), selector()) :: boolean()
  defp selected?(moment, fun) when is_function(fun, 1), do: fun.(moment)
  defp selected?(_moment, _selector), do: false

  @spec artifact_source(term()) :: term()
  defp artifact_source(binary) when is_binary(binary), do: binary
  defp artifact_source(term), do: term

  @spec to_text(term()) :: binary()
  defp to_text(input) when is_binary(input), do: input
  defp to_text(input), do: inspect(input)

  @spec secret_label(keyword(), map()) :: binary()
  defp secret_label(opts, metadata) do
    opts
    |> Keyword.get(:label, Map.get(metadata, :label, Map.get(metadata, "label", "secret")))
    |> to_string()
  end

  @spec redacted_secret_text(binary()) :: binary()
  defp redacted_secret_text(label), do: "secret: #{label}"

  @spec secret_metadata(map(), binary()) :: map()
  defp secret_metadata(metadata, label) do
    metadata
    |> Map.put(:secret?, true)
    |> Map.put(:label, label)
  end

  @spec secret_embedding_opts(keyword()) :: keyword()
  defp secret_embedding_opts(opts) do
    Keyword.drop(opts, [
      :secret_key,
      :secret_key_fun,
      :authorization_adapter,
      :authorization_context
    ])
  end

  @spec keywords(term()) :: [binary()]
  defp keywords(input) do
    input
    |> to_text()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @spec entities(term()) :: [binary()]
  defp entities(input) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, to_text(input))
    |> Enum.concat()
    |> Enum.uniq()
  end

  @spec fingerprint(term()) :: non_neg_integer()
  defp fingerprint(input) do
    Fingerprint.build(input)
  end
end
