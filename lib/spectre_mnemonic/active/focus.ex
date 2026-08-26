defmodule SpectreMnemonic.Active.Focus do
  @moduledoc """
  Projects active in-memory focus and writes important records to durable memory.

  Focus is the hot working set. It stores signals, moments, associations,
  artifacts, and task status in ETS so recall can stay fast while persistence is
  delegated to `SpectreMnemonic.Persistence.Manager`.
  """

  alias SpectreMnemonic.Active.BatchVisibility
  alias SpectreMnemonic.Active.Command
  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Active.Eviction
  alias SpectreMnemonic.Active.Projection, as: ActiveProjection
  alias SpectreMnemonic.Active.Repository
  alias SpectreMnemonic.Active.Status
  alias SpectreMnemonic.Active.Validation
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Erasure
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.ActionRecipe
  alias SpectreMnemonic.Memory.Artifact
  alias SpectreMnemonic.Memory.Association
  alias SpectreMnemonic.Memory.Episode
  alias SpectreMnemonic.Memory.Moment
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Memory.Signal
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Recall.Fingerprint
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Recall.Lexical
  alias SpectreMnemonic.Secrets

  @default_attention 1.0
  @kind_by_string %{
    "assistant" => :chat,
    "chat" => :chat,
    "code" => :code,
    "event" => :event,
    "note" => :note,
    "prompt" => :prompt,
    "secret" => :secret,
    "system" => :chat,
    "task" => :task,
    "text" => :text,
    "tool" => :tool,
    "user" => :chat
  }

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

  @doc "Stores a signal and returns the created signal and moment."
  @spec record_signal(input :: term(), opts :: keyword()) ::
          {:ok, record_result()} | {:error, term()}
  def record_signal(input, opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> record_signal_checked(input, opts) end)
    end
  end

  @doc "Returns the current status for a stream or task id."
  @spec status(stream_or_task_id :: term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def status(stream_or_task_id, opts \\ []) do
    with {:ok, namespace} <- Identity.fetch_namespace(opts) do
      Status.lookup({namespace, Keyword.get(opts, :scope)}, stream_or_task_id)
    end
  end

  @doc "Creates a graph edge between two memory records."
  @spec link(binary(), atom(), binary(), keyword()) ::
          {:ok, Association.t()} | {:error, :unknown_memory_id | term()}
  def link(source_id, relation, target_id, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> link_checked(source_id, relation, target_id, opts) end)
    end
  end

  @doc "Stores an artifact reference in ETS and on disk."
  @spec artifact(path_or_binary :: term(), opts :: keyword()) ::
          {:ok, Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}}
          | {:error, term()}
  def artifact(path_or_binary, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> artifact_checked(path_or_binary, opts) end)
    end
  end

  @doc "Forgets matching active memory records."
  @spec forget(selector(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget(selector, opts \\ [])

  def forget(selector, opts) when is_function(selector, 1) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> forget_moments(forget_ids(selector, opts), opts) end)
    end
  end

  def forget(selector, opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> forget_moments(forget_ids(selector, opts), opts) end)
    end
  end

  @doc false
  @spec rollback_intake(binary() | nil, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def rollback_intake(intake_run_id, opts) when is_binary(intake_run_id) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> do_rollback_intake(intake_run_id, opts) end)
    end
  end

  def rollback_intake(_intake_run_id, _opts), do: {:ok, 0}

  @doc "Returns all active moments. Recall and consolidation use this read path."
  @spec moments(keyword()) :: [Moment.t() | Secret.t()]
  def moments(opts \\ []) do
    namespace = Identity.namespace!(opts)

    :mnemonic_moments_by_scope
    |> indexed_ids({namespace, Scope.from_opts(opts)})
    |> moments_by_ids(opts)
  end

  @doc "Returns all active associations."
  @spec associations(keyword()) :: [Association.t()]
  def associations(opts \\ []) do
    namespace = Identity.namespace!(opts)

    :mnemonic_associations_by_scope
    |> indexed_ids({namespace, Scope.from_opts(opts)})
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_association/1)
    |> Enum.filter(&Scope.match?(&1, opts))
  end

  @doc false
  @spec episodes(keyword()) :: [Episode.t()]
  def episodes(opts \\ []) do
    namespace = Identity.namespace!(opts)

    hot =
      :mnemonic_episodes_by_scope
      |> indexed_ids({namespace, Scope.from_opts(opts)})
      |> Enum.uniq()
      |> Enum.flat_map(&lookup_episode/1)
      |> Enum.filter(&Scope.match?(&1, opts))

    durable = durable_episodes(opts)
    Enum.each(durable, &put_episode/1)

    (hot ++ durable)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  @doc false
  @spec hydrate_moment(Moment.t(), keyword()) :: :ok | {:error, term()}
  def hydrate_moment(%Moment{} = moment, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> do_hydrate_moment(moment, opts) end)
    end
  end

  @doc false
  @spec drop_episode(Episode.t(), keyword()) :: :ok | {:error, term()}
  def drop_episode(%Episode{} = episode, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> do_drop_episode(episode, opts) end)
    end
  end

  @doc false
  @spec upsert_association(Association.t()) :: :ok
  def upsert_association(%Association{} = association) do
    insert_association(association)
    :ok
  end

  @doc false
  @spec upsert_association_if_present(Association.t()) :: :ok | :missing
  def upsert_association_if_present(%Association{} = association) do
    Command.run_for_record(association, fn -> do_upsert_association_if_present(association) end)
  end

  @doc false
  @spec drop_association(Association.t()) :: :ok
  def drop_association(%Association{} = association) do
    Command.run_for_record(association, fn ->
      delete_association(association)
      :ok
    end)
  end

  @doc false
  @spec put_episode(Episode.t()) :: :ok
  def put_episode(%Episode{} = episode) do
    partition = Scope.partition(episode)
    ETS.insert(:mnemonic_episodes, {episode.id, episode})
    ETS.insert(:mnemonic_episodes_by_scope, {partition, episode.id})
    :ok
  end

  @doc false
  @spec purge_partition(keyword()) :: {:ok, map()} | {:error, term()}
  def purge_partition(opts) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn -> do_purge_partition(opts) end)
    end
  end

  @doc false
  @spec reinforce_attention([binary()], keyword()) :: :ok
  def reinforce_attention(ids, opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      Command.run(opts, fn ->
        Enum.each(Enum.uniq(ids), &reinforce_moment_attention(&1, opts))
        :ok
      end)
    end
  end

  @doc false
  @spec decay_attention_all(keyword()) :: {:ok, non_neg_integer()}
  def decay_attention_all(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      decay_attention_under_lock(opts)
    end
  end

  @doc false
  @spec validate_pinned_transition(binary(), atom(), keyword()) :: :ok | {:error, term()}
  def validate_pinned_transition(memory_id, :pinned, opts) do
    namespace = Identity.namespace!(opts)
    limit = Keyword.get(opts, :max_pinned_bytes, 128 * 1024 * 1024)

    case ETS.lookup(:mnemonic_moment_sizes, memory_id) do
      [{^memory_id, size, _partition, ^namespace, false}] ->
        if hot_bytes({:pinned, namespace}) + size <= limit,
          do: :ok,
          else: {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}}

      [{^memory_id, _size, _partition, ^namespace, true}] ->
        :ok

      [{^memory_id, size, _partition, ^namespace}] ->
        if hot_bytes({:pinned, namespace}) + size <= limit,
          do: :ok,
          else: {:error, {:mnemonic_limit_exceeded, :max_pinned_bytes}}

      _missing ->
        :ok
    end
  end

  def validate_pinned_transition(_memory_id, _state, _opts), do: :ok

  @doc false
  @spec sync_pinned_accounting(binary(), atom(), keyword()) :: :ok
  def sync_pinned_accounting(memory_id, state, opts) do
    namespace = Identity.namespace!(opts)
    pinned? = state == :pinned

    case ETS.lookup(:mnemonic_moment_sizes, memory_id) do
      [{^memory_id, size, partition, ^namespace, current}] when current != pinned? ->
        delta = if pinned?, do: size, else: -size
        adjust_hot_bytes({:pinned, namespace}, delta)
        ETS.insert(:mnemonic_moment_sizes, {memory_id, size, partition, namespace, pinned?})

        case lookup_moment(memory_id) do
          [moment] -> put_eviction_index(moment)
          [] -> :ok
        end

      [{^memory_id, size, partition, ^namespace}] ->
        if pinned?, do: adjust_hot_bytes({:pinned, namespace}, size)
        ETS.insert(:mnemonic_moment_sizes, {memory_id, size, partition, namespace, pinned?})

      _missing_or_unchanged ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec decay_attention_under_lock(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp decay_attention_under_lock(opts) do
    Command.run(opts, fn -> {:ok, decay_all_attention(opts)} end)
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
    limit = if is_integer(limit) and limit >= 0, do: limit, else: 0
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

  @spec do_drop_episode(Episode.t(), keyword()) :: :ok
  defp do_drop_episode(episode, opts) do
    episode.id
    |> List.wrap()
    |> associations_for_ids(opts)
    |> Enum.each(&delete_association/1)

    delete_episode(episode)
    :ok
  end

  @spec do_upsert_association_if_present(Association.t()) :: :ok | :missing
  defp do_upsert_association_if_present(association) do
    case ETS.lookup(:mnemonic_associations, association.id) do
      [{_id, %Association{}}] ->
        insert_association(association)
        :ok

      [] ->
        :missing
    end
  end

  @spec record_signal_checked(term(), keyword()) :: {:ok, record_result()} | {:error, term()}
  defp record_signal_checked(input, opts) do
    with :ok <- Erasure.ensure_writable(opts),
         :ok <- Validation.signal_options(opts) do
      if Keyword.get(opts, :secret?, false),
        do: record_secret_signal(input, opts),
        else: record_plain_signal(input, opts)
    end
  end

  @spec link_checked(binary(), atom(), binary(), keyword()) ::
          {:ok, Association.t()} | {:error, term()}
  defp link_checked(source_id, relation, target_id, opts) do
    with :ok <- Erasure.ensure_writable(opts),
         :ok <- Validation.link_request(source_id, relation, target_id, opts),
         {:ok, association_opts} <- association_context(source_id, target_id, opts) do
      association = build_association(source_id, relation, target_id, association_opts)

      case maybe_persist_value(:associations, association, association_opts) do
        {:ok, _association} = result ->
          insert_association(association)
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec artifact_checked(term(), keyword()) ::
          {:ok, Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}}
          | {:error, term()}
  defp artifact_checked(path_or_binary, opts) do
    with :ok <- Validation.structured_options(opts),
         artifact <- build_artifact(path_or_binary, opts),
         {:ok, artifact} <- persist_value(:artifacts, artifact, opts),
         {:ok, action_bundle} <-
           maybe_attach_action_recipe(artifact.id, opts, artifact.inserted_at) do
      ETS.insert(:mnemonic_artifacts, {artifact.id, artifact})
      insert_action_bundle(action_bundle)
      {:ok, artifact_result(artifact, action_recipe(action_bundle))}
    end
  end

  @spec record_plain_signal(term(), keyword()) :: {:ok, record_result()} | {:error, term()}
  defp record_plain_signal(input, opts) do
    now = DateTime.utc_now()
    stream = Keyword.get(opts, :stream) || :chat
    task_id = Keyword.get(opts, :task_id)
    kind = normalize_signal_kind(Keyword.get(opts, :kind, infer_kind(input, opts)), input)
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
    kind = normalize_signal_kind(Keyword.get(opts, :kind, :secret), input)
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
    with :ok <- validate_hot_record_size(moment, opts),
         {:ok, _signal_result} <- maybe_persist_value(:signals, signal, opts),
         {:ok, _moment_result} <- maybe_persist_value(:moments, moment, opts),
         :ok <- maybe_observe_moment(moment, opts),
         {:ok, action_bundle} <- maybe_attach_action_recipe(moment.id, opts, now) do
      # Durable writes are complete before any hot projection becomes visible.
      ETS.insert(:mnemonic_signals, {signal.id, signal})
      ETS.insert(:mnemonic_attention, {moment.id, moment.attention})
      insert_moment(moment, opts)
      Status.put(signal, now)
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

  @spec lookup_episode(binary()) :: [Episode.t()]
  defp lookup_episode(id), do: lookup_one(:mnemonic_episodes, id)

  @spec lookup_one(atom(), term()) :: [term()]
  defp lookup_one(table, id), do: Repository.lookup(table, id)

  @spec build_moment(Signal.t(), keyword(), DateTime.t()) :: Moment.t()
  defp build_moment(signal, opts, now) do
    embedding = Service.embed(signal.input, opts)
    temporal = Temporal.from_opts(opts, now)
    scope = Keyword.get(opts, :scope)

    metadata =
      signal.metadata
      |> Map.put_new(:scope, scope)
      |> Map.put_new(:durable?, Keyword.get(opts, :persist?, true))
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
        |> Map.put_new(:durable?, Keyword.get(opts, :persist?, true))
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
         key_id: Map.get(encrypted, :key_id),
         key_version: Map.get(encrypted, :key_version),
         crypto_version: Map.get(encrypted, :crypto_version),
         aad_version: Map.get(encrypted, :aad_version),
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
        |> Map.put_new(:durable?, Keyword.get(opts, :persist?, true))
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
    ETS.insert(:mnemonic_action_recipes, {recipe.id, recipe})
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

  @spec insert_moment(Moment.t() | Secret.t(), keyword()) :: true
  defp insert_moment(moment, opts \\ []) do
    existing = lookup_moment(moment.id)
    new? = existing == []

    case existing do
      [old] -> delete_eviction_index(old)
      [] -> :ok
    end

    ActiveProjection.put_moment(moment, opts)

    if new?, do: increment_moment_counts(moment)
    update_moment_bytes(existing, moment)
    put_eviction_index(moment)

    true
  end

  @spec do_hydrate_moment(Moment.t(), keyword()) :: :ok | {:error, term()}
  defp do_hydrate_moment(%Moment{} = moment, opts) do
    BatchVisibility.publish_record(moment)

    if Scope.match?(moment, opts) do
      ETS.insert(:mnemonic_attention, {moment.id, moment.attention})
      insert_moment(moment, opts)
      Index.upsert(moment)
      enforce_hot_bounds(moment, opts)
      :ok
    else
      {:error, :memory_partition_mismatch}
    end
  end

  @spec durable_episodes(keyword()) :: [Episode.t()]
  defp durable_episodes(opts) do
    case Manager.replay(opts) do
      {:ok, records} ->
        records
        |> Enum.filter(&(&1.family == :episodes))
        |> Enum.flat_map(fn
          %{payload: %Episode{} = episode} -> [episode]
          _record -> []
        end)

      {:error, _reason} ->
        []
    end
  end

  @spec insert_association(Association.t()) :: true
  defp insert_association(association), do: ActiveProjection.put_association(association)

  @spec forget_moments([binary()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp forget_moments([], _opts), do: {:ok, 0}

  defp forget_moments(ids, opts) do
    moments = moments_by_ids(ids, opts)

    with {:ok, plan} <- forget_plan(moments, opts),
         :ok <- persist_forget_plan(plan, opts),
         :ok <- persist_forgotten_states(plan, opts) do
      apply_forget_plan(plan)
      {:ok, length(moments)}
    end
  end

  @spec do_rollback_intake(binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp do_rollback_intake(intake_run_id, opts) do
    moments =
      opts
      |> moments()
      |> Enum.filter(&(Map.get(&1.metadata, :intake_run_id) == intake_run_id))

    if Keyword.get(opts, :persist?, false) do
      moments |> Enum.map(& &1.id) |> forget_moments(opts)
    else
      plan = hot_forget_plan(moments, opts)
      apply_forget_plan(plan)
      {:ok, length(moments)}
    end
  end

  @spec hot_forget_plan([Moment.t() | Secret.t()], keyword()) :: map()
  defp hot_forget_plan(moments, opts) do
    moment_ids = moments |> Enum.map(& &1.id) |> MapSet.new()
    signal_ids = moments |> Enum.map(& &1.signal_id) |> MapSet.new()
    associations = associations_for_ids(moment_ids, opts)

    episodes =
      opts
      |> episodes()
      |> Enum.filter(fn episode ->
        Enum.any?(episode.moment_ids, &MapSet.member?(moment_ids, &1))
      end)

    episode_associations =
      episodes
      |> Enum.map(& &1.id)
      |> associations_for_ids(opts)

    associations = Enum.uniq_by(associations ++ episode_associations, & &1.id)

    recipe_ids =
      associations
      |> Enum.filter(
        &(&1.relation == :attached_action and MapSet.member?(moment_ids, &1.source_id))
      )
      |> Enum.map(& &1.target_id)
      |> MapSet.new()

    %{
      moments: moments,
      moment_ids: moment_ids,
      signal_ids: signal_ids,
      associations: associations,
      recipe_ids: recipe_ids,
      episodes: episodes
    }
  end

  @spec forget_plan([Moment.t() | Secret.t()], keyword()) :: {:ok, map()} | {:error, term()}
  defp forget_plan(moments, opts) do
    moment_ids = moments |> Enum.map(& &1.id) |> MapSet.new()
    signal_ids = moments |> Enum.map(& &1.signal_id) |> MapSet.new()

    direct_associations =
      moment_ids
      |> associations_for_ids(opts)

    episodes =
      opts
      |> episodes()
      |> Enum.filter(fn episode ->
        Enum.any?(episode.moment_ids, &MapSet.member?(moment_ids, &1))
      end)

    episode_associations =
      episodes
      |> Enum.map(& &1.id)
      |> associations_for_ids(opts)

    associations = Enum.uniq_by(direct_associations ++ episode_associations, & &1.id)
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
      durable_memory_ids =
        targets
        |> Enum.filter(fn {family, _id} -> family == :moments end)
        |> Enum.map(fn {_family, id} -> id end)
        |> MapSet.new()

      {:ok,
       %{
         moments: moments,
         moment_ids: moment_ids,
         signal_ids: signal_ids,
         associations: associations,
         association_ids: association_ids,
         recipe_ids: recipe_ids,
         episodes: episodes,
         durable_memory_ids: durable_memory_ids,
         durable_targets: targets
       }}
    end
  end

  @spec durable_forget_targets(MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t(), keyword()) ::
          {:ok, [{atom(), binary()}]} | {:error, term()}
  defp durable_forget_targets(moment_ids, signal_ids, association_ids, recipe_ids, opts) do
    requested =
      Enum.concat([
        Enum.map(moment_ids, &{:moments, &1}),
        Enum.map(signal_ids, &{:signals, &1}),
        Enum.map(association_ids, &{:associations, &1}),
        Enum.map(recipe_ids, &{:action_recipes, &1})
      ])

    case Manager.replay(opts) do
      {:ok, records} ->
        ids = MapSet.union(moment_ids, signal_ids)
        requested = MapSet.new(requested)

        targets =
          records
          |> Enum.reject(&(&1.family == :tombstones))
          |> Enum.filter(fn record ->
            record_id = payload_id(record.payload)

            (is_binary(record_id) and MapSet.member?(requested, {record.family, record_id})) or
              record_references?(record.payload, ids)
          end)
          |> Enum.flat_map(fn record ->
            case payload_id(record.payload) do
              id when is_binary(id) -> [{record.family, id}]
              _missing -> []
            end
          end)

        {:ok, Enum.uniq(targets)}

      {:error, _reason} = error ->
        error
    end
  end

  @spec record_references?(term(), MapSet.t()) :: boolean()
  defp record_references?(payload, ids) when is_map(payload) do
    direct_ids =
      [:id, :source_id, :memory_id, :signal_id, :target_id]
      |> Enum.flat_map(&map_values(payload, &1))
      |> Enum.concat(referenced_id_lists(payload))
      |> Enum.concat(provenance_source_ids(payload))

    Enum.any?(direct_ids, &MapSet.member?(ids, &1))
  end

  defp record_references?(_payload, _ids), do: false

  @spec referenced_id_lists(map()) :: [term()]
  defp referenced_id_lists(payload) do
    [:source_ids, :moment_ids]
    |> Enum.flat_map(fn key -> payload |> map_values(key) |> Enum.flat_map(&List.wrap/1) end)
  end

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

  @spec persist_forgotten_states(map(), keyword()) :: :ok | {:error, term()}
  defp persist_forgotten_states(plan, opts) do
    Enum.reduce_while(plan.moments, :ok, fn moment, :ok ->
      persist_forgotten_state(moment, plan.durable_memory_ids, opts)
    end)
  end

  @spec persist_forgotten_state(Moment.t() | Secret.t(), MapSet.t(), keyword()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp persist_forgotten_state(moment, durable_memory_ids, opts) do
    if MapSet.member?(durable_memory_ids, moment.id) do
      case Governance.forget(moment.id, context_opts(moment, opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, :ok}
    end
  end

  @spec apply_forget_plan(map()) :: :ok
  defp apply_forget_plan(plan) do
    Enum.each(plan.associations, &delete_association/1)
    Enum.each(plan.episodes, &delete_episode/1)
    Enum.each(plan.recipe_ids, &ETS.delete(:mnemonic_action_recipes, &1))
    Enum.each(plan.signal_ids, &ETS.delete(:mnemonic_signals, &1))
    Enum.each(plan.moments, &evict_hot_moment/1)
    delete_derived_hot_records(plan.moment_ids)
    :ok
  end

  @spec delete_episode(Episode.t()) :: true
  defp delete_episode(episode) do
    partition = Scope.partition(episode)
    ETS.delete(:mnemonic_episodes, episode.id)
    ETS.delete_object(:mnemonic_episodes_by_scope, {partition, episode.id})
  end

  @spec delete_derived_hot_records(MapSet.t()) :: :ok
  defp delete_derived_hot_records(moment_ids) do
    Enum.each([:mnemonic_observations, :mnemonic_mental_models], fn table ->
      table
      |> ETS.tab2list()
      |> Enum.each(&delete_referencing_record(&1, table, moment_ids))
    end)

    :ok
  end

  @spec delete_referencing_record({term(), map()}, atom(), MapSet.t()) :: true | nil
  defp delete_referencing_record({id, record}, table, moment_ids) do
    if record_references?(record, moment_ids) do
      delete_derived_scope_index(table, record, id)
      ETS.delete(table, id)
    end
  end

  @spec delete_derived_scope_index(atom(), map(), term()) :: true | :ok
  defp delete_derived_scope_index(:mnemonic_observations, record, id),
    do: ETS.delete_object(:mnemonic_observations_by_scope, {Scope.partition(record), id})

  defp delete_derived_scope_index(:mnemonic_mental_models, record, id),
    do: ETS.delete_object(:mnemonic_mental_models_by_scope, {Scope.partition(record), id})

  defp delete_derived_scope_index(_table, _record, _id), do: :ok

  @spec delete_association(Association.t()) :: true
  defp delete_association(association), do: ActiveProjection.delete_association(association)

  @spec delete_moment_indexes(Moment.t() | Secret.t()) :: :ok
  defp delete_moment_indexes(moment) do
    ActiveProjection.delete_moment_indexes(moment)

    delete_eviction_index(moment)
    delete_moment_bytes(moment.id)
    decrement_moment_counts(moment)
  end

  @spec update_moment_bytes([Moment.t() | Secret.t()], Moment.t() | Secret.t()) :: :ok
  defp update_moment_bytes(existing, moment) do
    Eviction.replace_bytes(existing, moment, pinned?(moment, context_opts(moment, [])))
  end

  @spec delete_moment_bytes(binary()) :: :ok
  defp delete_moment_bytes(id), do: Eviction.delete_bytes(id)

  @spec adjust_hot_bytes(tuple(), integer()) :: :ok
  defp adjust_hot_bytes(key, delta), do: Eviction.adjust_bytes(key, delta)

  @spec increment_moment_counts(Moment.t() | Secret.t()) :: :ok
  defp increment_moment_counts(moment), do: Eviction.increment_count(moment)

  @spec decrement_moment_counts(Moment.t() | Secret.t()) :: :ok
  defp decrement_moment_counts(moment), do: Eviction.decrement_count(moment)

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
  defp indexed_ids(table, key), do: Repository.indexed_ids(table, key)

  @spec direct_moment_ids(binary()) :: [binary()]
  defp direct_moment_ids(id) do
    case lookup_moment(id) do
      [_moment] -> [id]
      [] -> []
    end
  end

  @spec infer_kind(term(), keyword()) :: atom()
  defp infer_kind(input, _opts) when is_binary(input), do: :text
  defp infer_kind(%{kind: kind}, _opts), do: kind
  defp infer_kind(%{"kind" => kind}, _opts), do: kind
  defp infer_kind(%{type: kind}, _opts), do: kind
  defp infer_kind(%{"type" => kind}, _opts), do: kind
  defp infer_kind(_input, _opts), do: :event

  @spec normalize_signal_kind(term(), term()) :: atom()
  defp normalize_signal_kind(kind, _input)
       when is_atom(kind) and kind not in [nil, true, false],
       do: kind

  defp normalize_signal_kind(kind, input) when is_binary(kind) do
    Map.get(@kind_by_string, String.downcase(String.trim(kind)), default_signal_kind(input))
  end

  defp normalize_signal_kind(_kind, input), do: default_signal_kind(input)

  @spec default_signal_kind(term()) :: :text | :event
  defp default_signal_kind(input) when is_binary(input), do: :text
  defp default_signal_kind(_input), do: :event

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
    per_scope = hot_limit(:max_moments_per_scope, 1_000)
    per_namespace = hot_limit(:max_moments_per_namespace, 10_000)
    partition = Scope.partition(moment)
    evict_until({:scope, partition}, {:scope, partition}, per_scope, opts)

    namespace = Identity.namespace(moment)
    evict_until({:namespace, namespace}, {:namespace, namespace}, per_namespace, opts)

    evict_bytes_until(
      {:scope, partition},
      {:scope, partition},
      Keyword.get(opts, :max_hot_bytes_per_scope, 64 * 1024 * 1024),
      opts
    )

    evict_bytes_until(
      {:namespace, namespace},
      {:namespace, namespace},
      Keyword.get(opts, :max_hot_bytes_per_engine, 512 * 1024 * 1024),
      opts
    )

    :ok
  end

  @spec validate_hot_record_size(Moment.t() | Secret.t(), keyword()) :: :ok | {:error, term()}
  defp validate_hot_record_size(moment, opts), do: Eviction.validate_size(moment, opts)

  @spec moment_count(term()) :: non_neg_integer()
  defp moment_count(key), do: Eviction.count(key)

  @spec hot_limit(atom(), non_neg_integer()) :: non_neg_integer()
  defp hot_limit(key, default) do
    configured = hot_memory_config()

    case Map.get(configured, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  @spec evict_until(tuple(), tuple(), non_neg_integer(), keyword()) :: :ok
  defp evict_until(axis, count_key, limit, opts) do
    if moment_count(count_key) > limit do
      case next_eviction_candidate(axis, opts) do
        nil ->
          :ok

        moment ->
          evict_hot_moment(moment)
          evict_until(axis, count_key, limit, opts)
      end
    else
      :ok
    end
  end

  @spec evict_bytes_until(tuple(), tuple(), non_neg_integer(), keyword()) :: :ok
  defp evict_bytes_until(axis, count_key, limit, opts) do
    if hot_bytes(count_key) > limit do
      case next_eviction_candidate(axis, opts) do
        nil ->
          :ok

        moment ->
          evict_hot_moment(moment)
          evict_bytes_until(axis, count_key, limit, opts)
      end
    else
      :ok
    end
  end

  @spec hot_bytes(tuple()) :: non_neg_integer()
  defp hot_bytes(key), do: Eviction.hot_bytes(key)

  @spec next_eviction_candidate(tuple(), keyword()) :: Moment.t() | Secret.t() | nil
  defp next_eviction_candidate(axis, opts) do
    start = {axis, -1, -1.0, -1, ""}

    case ETS.next(:mnemonic_moment_eviction, start) do
      {^axis, 1, _attention, _inserted_at, _id} ->
        nil

      {^axis, 0, _attention, _inserted_at, id} ->
        resolve_eviction_candidate(id, axis, opts)

      _end_or_other_axis ->
        nil
    end
  end

  @spec resolve_eviction_candidate(binary(), tuple(), keyword()) ::
          Moment.t() | Secret.t() | nil
  defp resolve_eviction_candidate(id, axis, opts) do
    case lookup_moment(id) do
      [moment] ->
        if pinned?(moment, opts) do
          put_eviction_index(moment)
          next_eviction_candidate(axis, opts)
        else
          moment
        end

      [] ->
        delete_stale_eviction_key(id)
        next_eviction_candidate(axis, opts)
    end
  end

  @spec put_eviction_index(Moment.t() | Secret.t()) :: true
  defp put_eviction_index(moment) do
    Eviction.put_index(
      moment,
      pinned?(moment, context_opts(moment, [])),
      current_attention(moment)
    )
  end

  @spec delete_eviction_index(Moment.t() | Secret.t()) :: true
  defp delete_eviction_index(moment), do: Eviction.delete_index(moment)

  @spec delete_stale_eviction_key(binary()) :: true
  defp delete_stale_eviction_key(id), do: Eviction.delete_index(id)

  @spec pinned?(Moment.t() | Secret.t(), keyword()) :: boolean()
  defp pinned?(moment, opts) do
    Governance.state_for(moment.id, context_opts(moment, opts)) == :pinned
  end

  @spec current_attention(Moment.t() | Secret.t()) :: float()
  defp current_attention(moment) do
    case ETS.lookup(:mnemonic_attention, moment.id) do
      [{_id, attention}] when is_number(attention) -> attention * 1.0
      _missing -> moment.attention * 1.0
    end
  end

  @spec reinforce_moment_attention(binary(), keyword()) :: :ok
  defp reinforce_moment_attention(id, opts) do
    case lookup_moment(id) do
      [moment] ->
        if Scope.match?(moment, opts) do
          config = hot_memory_config()
          rate = bounded_config(config, :recall_reinforcement, 0.15, 0.0, 10.0)
          cap = bounded_config(config, :attention_cap, 10.0, 1.0, 1_000.0)
          attention = min(current_attention(moment) + rate, cap)
          now = DateTime.utc_now()

          updated = %{
            moment
            | attention: attention,
              metadata: Map.put(moment.metadata, :last_recalled_at, now)
          }

          update_hot_attention(updated)
        end

      [] ->
        :ok
    end

    :ok
  end

  @spec decay_all_attention(keyword()) :: non_neg_integer()
  defp decay_all_attention(opts) do
    config = hot_memory_config()
    factor = bounded_config(config, :attention_decay_factor, 0.98, 0.0, 1.0)
    floor = bounded_config(config, :attention_floor, 0.1, 0.0, 1_000.0)

    stale_after =
      case Map.get(
             config,
             :attention_stale_after_ms,
             Keyword.get(opts, :stale_after_ms, 86_400_000)
           ) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> 86_400_000
      end

    cutoff = DateTime.add(DateTime.utc_now(), -stale_after, :millisecond)
    namespace = Identity.namespace!(opts)

    :mnemonic_moments
    |> ETS.tab2list()
    |> Enum.reduce(0, fn {_id, moment}, count ->
      maybe_decay_attention(moment, count, namespace, cutoff, factor, floor, opts)
    end)
  end

  @spec maybe_decay_attention(
          Moment.t() | Secret.t(),
          non_neg_integer(),
          binary(),
          DateTime.t(),
          float(),
          float(),
          keyword()
        ) :: non_neg_integer()
  defp maybe_decay_attention(moment, count, namespace, cutoff, factor, floor, opts) do
    eligible? =
      moment.namespace == namespace and attention_stale?(moment, cutoff) and
        not pinned?(moment, context_opts(moment, opts))

    if eligible? do
      apply_attention_decay(moment, count, factor, floor)
    else
      count
    end
  end

  @spec apply_attention_decay(Moment.t() | Secret.t(), non_neg_integer(), float(), float()) ::
          non_neg_integer()
  defp apply_attention_decay(moment, count, factor, floor) do
    current = current_attention(moment)
    attention = max(current * factor, floor)

    if attention < current do
      update_hot_attention(%{moment | attention: attention})
      count + 1
    else
      count
    end
  end

  @spec attention_stale?(Moment.t() | Secret.t(), DateTime.t()) :: boolean()
  defp attention_stale?(moment, cutoff) do
    timestamp = Map.get(moment.metadata, :last_recalled_at) || moment.inserted_at
    match?(%DateTime{}, timestamp) and DateTime.compare(timestamp, cutoff) in [:lt, :eq]
  end

  @spec update_hot_attention(Moment.t() | Secret.t()) :: :ok
  defp update_hot_attention(moment) do
    ETS.insert(:mnemonic_attention, {moment.id, moment.attention})
    insert_moment(moment)
    :ok
  end

  @spec hot_memory_config :: map()
  defp hot_memory_config do
    case Application.get_env(:spectre_mnemonic, :hot_memory, []) do
      config when is_map(config) -> config
      config when is_list(config) -> if(Keyword.keyword?(config), do: Map.new(config), else: %{})
      _invalid -> %{}
    end
  end

  @spec bounded_config(map(), atom(), number(), number(), number()) :: float()
  defp bounded_config(config, key, default, minimum, maximum) do
    case Map.get(config, key, default) do
      value when is_number(value) -> (value * 1.0) |> max(minimum) |> min(maximum)
      _invalid -> default * 1.0
    end
  end

  @spec evict_hot_moment(Moment.t() | Secret.t()) :: :ok
  defp evict_hot_moment(moment) do
    associations = associations_for_ids([moment.id], context_opts(moment, []))

    recipe_ids =
      associations
      |> Enum.filter(&(&1.relation == :attached_action and &1.source_id == moment.id))
      |> Enum.map(& &1.target_id)

    Enum.each(associations, &delete_association/1)
    Enum.each(recipe_ids, &ETS.delete(:mnemonic_action_recipes, &1))
    delete_moment_indexes(moment)
    ETS.delete(:mnemonic_moments, moment.id)
    ETS.delete(:mnemonic_attention, moment.id)
    ETS.delete(:mnemonic_signals, moment.signal_id)
    ETS.delete_object(:mnemonic_atlas_dirty, {Scope.partition(moment), moment.id})
    Status.refresh(moment)
    Index.delete(moment)
    ActiveProjection.delete_candidate(moment)
    :ok
  end

  @spec do_purge_partition(keyword()) :: {:ok, map()}
  defp do_purge_partition(opts) do
    namespace = Identity.namespace!(opts)
    partition = {namespace, Scope.from_opts(opts)}
    moments = moments(opts)
    associations = associations(opts)
    episodes = episodes(opts)

    Enum.each(associations, &delete_association/1)
    Enum.each(moments, &evict_hot_moment/1)

    Enum.each(episodes, fn episode ->
      ETS.delete(:mnemonic_episodes, episode.id)
      ETS.delete_object(:mnemonic_episodes_by_scope, {partition, episode.id})
    end)

    direct_tables = [
      :mnemonic_signals,
      :mnemonic_artifacts,
      :mnemonic_action_recipes,
      :mnemonic_observations,
      :mnemonic_mental_models,
      :mnemonic_governance_states,
      :mnemonic_governance_facts
    ]

    direct_removed =
      Enum.reduce(direct_tables, 0, fn table, count ->
        count + delete_partition_rows(table, partition)
      end)

    ETS.match_delete(:mnemonic_status, {{partition, :_}, :_})
    ETS.match_delete(:mnemonic_entity_registry, {{partition, :_}, :_})
    ETS.match_delete(:mnemonic_atlas_dirty, {partition, :_})
    ETS.match_delete(:mnemonic_observations_by_scope, {partition, :_})
    ETS.match_delete(:mnemonic_mental_models_by_scope, {partition, :_})
    ETS.match_delete(:mnemonic_governance_states_by_scope, {partition, :_})

    {:ok,
     %{
       moments: length(moments),
       associations: length(associations),
       episodes: length(episodes),
       other: direct_removed
     }}
  end

  @spec delete_partition_rows(atom(), tuple()) :: non_neg_integer()
  defp delete_partition_rows(table, partition) do
    table
    |> ETS.tab2list()
    |> Enum.count(&delete_partition_row(&1, table, partition))
  end

  @spec delete_partition_row({term(), term()}, atom(), tuple()) :: boolean()
  defp delete_partition_row({id, value}, table, partition) do
    if Scope.partition(value) == partition do
      ETS.delete(table, id)
      true
    else
      false
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
  defp selected?(moment, fun) when is_function(fun, 1) do
    fun.(moment) == true
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp selected?(_moment, _selector), do: false

  @spec artifact_source(term()) :: term()
  defp artifact_source(binary) when is_binary(binary), do: binary
  defp artifact_source(term), do: term

  @spec to_text(term()) :: binary()
  defp to_text(input) when is_binary(input), do: input
  defp to_text(input), do: inspect(input)

  @spec secret_label(keyword(), map()) :: binary()
  defp secret_label(opts, metadata) do
    case Keyword.get(
           opts,
           :label,
           Map.get(metadata, :label, Map.get(metadata, "label", "secret"))
         ) do
      label when is_binary(label) -> label
      label when is_atom(label) or is_number(label) -> to_string(label)
      label -> inspect(label)
    end
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
  defp keywords(input), do: Lexical.keywords(to_text(input))

  @spec entities(term()) :: [binary()]
  defp entities(input), do: Lexical.entities(to_text(input))

  @spec fingerprint(term()) :: non_neg_integer()
  defp fingerprint(input) do
    Fingerprint.build(input)
  end
end
