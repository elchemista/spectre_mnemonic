defmodule SpectreMnemonic.Focus do
  @moduledoc """
  Owns active in-memory focus and writes important records to durable memory.

  Focus is the hot working set. It stores signals, moments, associations,
  artifacts, and task status in ETS so recall can stay fast while persistence is
  delegated to `SpectreMnemonic.PersistentMemory`.
  """

  use GenServer

  alias SpectreMnemonic.{ActionRecipe, Artifact, Association, Moment, PersistentMemory, Signal}
  alias SpectreMnemonic.Recall.Index
  alias SpectreMnemonic.Store.ETSOwner

  @default_attention 1.0

  @type state :: map()
  @type selector ::
          binary()
          | {:stream, term()}
          | {:task, term()}
          | (Moment.t() -> boolean())
  @type record_result :: %{
          required(:signal) => Signal.t(),
          required(:moment) => Moment.t(),
          optional(:action_recipe) => ActionRecipe.t()
        }

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
    GenServer.call(__MODULE__, {:record_signal, input, opts})
  end

  @doc "Returns the current status for a stream or task id."
  @spec status(stream_or_task_id :: term()) :: {:ok, map()} | {:error, :not_found}
  def status(stream_or_task_id) do
    case :ets.lookup(:mnemonic_status, stream_or_task_id) do
      [{^stream_or_task_id, status}] -> {:ok, status}
      [] -> {:error, :not_found}
    end
  end

  @doc "Creates a graph edge between two memory records."
  @spec link(binary(), atom(), binary(), keyword()) ::
          {:ok, Association.t()} | {:error, :unknown_memory_id | term()}
  def link(source_id, relation, target_id, opts \\ []) do
    GenServer.call(__MODULE__, {:link, source_id, relation, target_id, opts})
  end

  @doc "Stores an artifact reference in ETS and on disk."
  @spec artifact(path_or_binary :: term(), opts :: keyword()) ::
          {:ok, Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}}
          | {:error, term()}
  def artifact(path_or_binary, opts \\ []) do
    GenServer.call(__MODULE__, {:artifact, path_or_binary, opts})
  end

  @doc "Forgets matching active memory records."
  @spec forget(selector(), keyword()) :: {:ok, non_neg_integer()}
  def forget(selector, opts \\ []) do
    GenServer.call(__MODULE__, {:forget, selector, opts})
  end

  @doc "Returns all active moments. Recall and consolidation use this read path."
  @spec moments :: [Moment.t()]
  def moments do
    :ets.tab2list(:mnemonic_moments)
    |> Enum.map(fn {_id, moment} -> moment end)
  end

  @doc "Returns all active associations."
  @spec associations :: [Association.t()]
  def associations do
    :ets.tab2list(:mnemonic_associations)
    |> Enum.map(fn {_id, association} -> association end)
  end

  @doc "Returns active artifacts by id."
  @spec artifacts([binary()]) :: [Artifact.t()]
  def artifacts(ids) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_artifact/1)
  end

  @doc "Returns active action recipes by id."
  @spec action_recipes([binary()]) :: [ActionRecipe.t()]
  def action_recipes(ids) do
    ids
    |> Enum.uniq()
    |> Enum.flat_map(&lookup_action_recipe/1)
  end

  @impl true
  @spec init(state()) :: {:ok, state()}
  def init(state), do: {:ok, state}

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()}
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

    with {:ok, _signal_result} <- PersistentMemory.append(:signals, signal),
         {:ok, _moment_result} <- PersistentMemory.append(:moments, moment),
         {:ok, action_recipe} <- maybe_attach_action_recipe(moment.id, opts, now) do
      Index.upsert(moment)
      {:reply, {:ok, record_signal_result(signal, moment, action_recipe)}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:link, source_id, relation, target_id, opts}, _from, state) do
    if memory_id?(source_id) and memory_id?(target_id) do
      association = build_association(source_id, relation, target_id, opts)
      :ets.insert(:mnemonic_associations, {association.id, association})

      {:reply, persist_value(:associations, association), state}
    else
      {:reply, {:error, :unknown_memory_id}, state}
    end
  end

  def handle_call({:artifact, path_or_binary, opts}, _from, state) do
    artifact = build_artifact(path_or_binary, opts)
    :ets.insert(:mnemonic_artifacts, {artifact.id, artifact})

    result =
      with {:ok, artifact} <- persist_value(:artifacts, artifact),
           {:ok, action_recipe} <-
             maybe_attach_action_recipe(artifact.id, opts, artifact.inserted_at) do
        {:ok, artifact_result(artifact, action_recipe)}
      end

    {:reply, result, state}
  end

  def handle_call({:forget, selector, _opts}, _from, state) do
    forget_ids =
      moments()
      |> Enum.filter(&selected?(&1, selector))
      |> Enum.map(& &1.id)

    Enum.each(forget_ids, &forget_moment/1)

    {:reply, {:ok, length(forget_ids)}, state}
  end

  @spec lookup_artifact(binary()) :: [Artifact.t()]
  defp lookup_artifact(id) do
    case :ets.lookup(:mnemonic_artifacts, id) do
      [{^id, artifact}] -> [artifact]
      [] -> []
    end
  end

  @spec lookup_action_recipe(binary()) :: [ActionRecipe.t()]
  defp lookup_action_recipe(id) do
    case :ets.lookup(:mnemonic_action_recipes, id) do
      [{^id, action_recipe}] -> [action_recipe]
      [] -> []
    end
  end

  @spec build_moment(Signal.t(), keyword(), DateTime.t()) :: Moment.t()
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

  @spec build_association(binary(), atom(), binary(), keyword()) :: Association.t()
  defp build_association(source_id, relation, target_id, opts) do
    %Association{
      id: id("assoc"),
      source_id: source_id,
      relation: relation,
      target_id: target_id,
      weight: Keyword.get(opts, :weight, 1.0),
      metadata: Map.new(Keyword.get(opts, :metadata, %{})),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec build_artifact(term(), keyword()) :: Artifact.t()
  defp build_artifact(path_or_binary, opts) do
    %Artifact{
      id: id("art"),
      source: artifact_source(path_or_binary),
      content_type: Keyword.get(opts, :content_type),
      metadata: Map.new(Keyword.get(opts, :metadata, %{})),
      inserted_at: DateTime.utc_now()
    }
  end

  @spec maybe_attach_action_recipe(binary(), keyword(), DateTime.t()) ::
          {:ok, ActionRecipe.t() | nil} | {:error, term()}
  defp maybe_attach_action_recipe(memory_id, opts, now) do
    case build_action_recipe(memory_id, opts, now) do
      nil ->
        {:ok, nil}

      action_recipe ->
        :ets.insert(:mnemonic_action_recipes, {action_recipe.id, action_recipe})

        with {:ok, _recipe_result} <- PersistentMemory.append(:action_recipes, action_recipe),
             {:ok, _association} <-
               persist_attached_action(memory_id, action_recipe.id, action_recipe.inserted_at) do
          {:ok, action_recipe}
        end
    end
  end

  @spec build_action_recipe(binary(), keyword(), DateTime.t()) :: ActionRecipe.t() | nil
  defp build_action_recipe(memory_id, opts, now) do
    case Keyword.get(opts, :action_recipe) do
      recipe when is_binary(recipe) and recipe != "" ->
        action_recipe_from_text(memory_id, recipe, opts, now)

      recipe when is_map(recipe) ->
        action_recipe_from_map(recipe, memory_id, opts, now)

      recipe when is_list(recipe) ->
        recipe |> Map.new() |> action_recipe_from_map(memory_id, opts, now)

      _missing ->
        nil
    end
  end

  @spec action_recipe_from_text(binary(), binary(), keyword(), DateTime.t()) :: ActionRecipe.t()
  defp action_recipe_from_text(memory_id, text, opts, now) do
    %ActionRecipe{
      id: id("act"),
      memory_id: memory_id,
      language: Keyword.get(opts, :action_language, :spectre_al),
      text: text,
      intent: Keyword.get(opts, :action_intent),
      status: Keyword.get(opts, :action_status, :stored),
      metadata: action_metadata(opts, %{}),
      inserted_at: now
    }
  end

  @spec action_recipe_from_map(map(), binary(), keyword(), DateTime.t()) :: ActionRecipe.t()
  defp action_recipe_from_map(recipe, memory_id, opts, now) do
    metadata = recipe_value(recipe, :metadata, %{})

    %ActionRecipe{
      id: recipe_value(recipe, :id, id("act")),
      memory_id: recipe_value(recipe, :memory_id, memory_id),
      language: recipe_value(recipe, :language, :spectre_al),
      text: recipe_value(recipe, :text, ""),
      intent: recipe_value(recipe, :intent, Keyword.get(opts, :action_intent)),
      status: recipe_value(recipe, :status, :stored),
      metadata: action_metadata(opts, metadata),
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

  @spec persist_attached_action(binary(), binary(), DateTime.t()) ::
          {:ok, Association.t()} | {:error, term()}
  defp persist_attached_action(memory_id, action_recipe_id, now) do
    association = %Association{
      id: id("assoc"),
      source_id: memory_id,
      relation: :attached_action,
      target_id: action_recipe_id,
      weight: 1.0,
      metadata: %{language: :spectre_al},
      inserted_at: now
    }

    :ets.insert(:mnemonic_associations, {association.id, association})
    persist_value(:associations, association)
  end

  @spec record_signal_result(Signal.t(), Moment.t(), ActionRecipe.t() | nil) :: record_result()
  defp record_signal_result(signal, moment, nil), do: %{signal: signal, moment: moment}

  defp record_signal_result(signal, moment, action_recipe) do
    %{signal: signal, moment: moment, action_recipe: action_recipe}
  end

  @spec artifact_result(Artifact.t(), ActionRecipe.t() | nil) ::
          Artifact.t() | %{artifact: Artifact.t(), action_recipe: ActionRecipe.t()}
  defp artifact_result(artifact, nil), do: artifact

  defp artifact_result(artifact, action_recipe),
    do: %{artifact: artifact, action_recipe: action_recipe}

  @spec persist_value(atom(), term()) :: {:ok, term()} | {:error, term()}
  defp persist_value(family, value) do
    case PersistentMemory.append(family, value) do
      {:ok, _result} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec forget_moment(binary()) :: :ok
  defp forget_moment(id) do
    :ets.delete(:mnemonic_moments, id)
    :ets.delete(:mnemonic_attention, id)
    Index.delete(id)

    PersistentMemory.append(:tombstones, %{
      family: :moments,
      id: id,
      forgotten_at: DateTime.utc_now()
    })

    :ok
  end

  @spec update_status(term(), term(), term(), atom(), DateTime.t()) :: true
  defp update_status(stream, task_id, input, kind, now) do
    status = %{stream: stream, task_id: task_id, kind: kind, last_input: input, updated_at: now}
    :ets.insert(:mnemonic_status, {stream, status})
    if task_id, do: :ets.insert(:mnemonic_status, {task_id, status})
  end

  @spec infer_kind(term(), keyword()) :: atom()
  defp infer_kind(input, _opts) when is_binary(input), do: :text
  defp infer_kind(%{kind: kind}, _opts), do: kind
  defp infer_kind(_input, _opts), do: :event

  @spec memory_id?(binary()) :: boolean()
  defp memory_id?(id) do
    ETSOwner.member?(:mnemonic_moments, id) or ETSOwner.member?(:mnemonic_signals, id) or
      ETSOwner.member?(:mnemonic_artifacts, id) or ETSOwner.member?(:mnemonic_action_recipes, id)
  end

  @spec selected?(Moment.t(), selector()) :: boolean()
  defp selected?(moment, id) when is_binary(id), do: moment.id == id or moment.signal_id == id
  defp selected?(moment, {:stream, stream}), do: moment.stream == stream
  defp selected?(moment, {:task, task_id}), do: moment.task_id == task_id
  defp selected?(moment, fun) when is_function(fun, 1), do: fun.(moment)
  defp selected?(_moment, _selector), do: false

  @spec artifact_source(term()) :: term()
  defp artifact_source(binary) when is_binary(binary), do: binary
  defp artifact_source(term), do: term

  @spec to_text(term()) :: binary()
  defp to_text(input) when is_binary(input), do: input
  defp to_text(input), do: inspect(input)

  @spec keywords(term()) :: [binary()]
  defp keywords(input) do
    input
    |> to_text()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.uniq()
  end

  @spec entities(term()) :: [binary()]
  defp entities(input) do
    Regex.scan(~r/\b[A-Z][A-Za-z0-9_]+\b/, to_text(input))
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec fingerprint(term()) :: non_neg_integer()
  defp fingerprint(input) do
    SpectreMnemonic.Fingerprint.build(input)
  end

  @spec id(binary()) :: binary()
  defp id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end
end
