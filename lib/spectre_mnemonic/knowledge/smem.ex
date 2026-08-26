defmodule SpectreMnemonic.Knowledge.SMEM do
  @moduledoc """
  Compact append-only knowledge event log.

  The file lives at `data_root/knowledge/knowledge.smem` and uses the same
  framed binary style as the default file store: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload.
  """

  use GenServer

  @magic "SKNW"
  @version 1
  @max_text_graphemes 2_000

  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Erasure
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Knowledge.Projection
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Persistence.FramedLog
  alias SpectreMnemonic.Persistence.Store.FileFrame
  alias SpectreMnemonic.Persistence.StoreWriter
  alias SpectreMnemonic.Result

  @event_types [:summary, :skill, :latest_ingestion, :fact, :procedure, :compaction_marker]
  @event_type_by_string Map.new(@event_types, &{Atom.to_string(&1), &1})
  @event_keys ~w(id namespace scope type text summary name steps value source_id usage metadata inserted_at)a
  @event_key_by_string Map.new(@event_keys, &{Atom.to_string(&1), &1})

  @type event_type ::
          :summary | :skill | :latest_ingestion | :fact | :procedure | :compaction_marker

  @type event :: %{
          optional(:id) => binary(),
          optional(:namespace) => binary(),
          optional(:scope) => term(),
          optional(:type) => event_type(),
          optional(:text) => binary(),
          optional(:summary) => binary(),
          optional(:name) => binary(),
          optional(:steps) => [term()],
          optional(:value) => term(),
          optional(:source_id) => binary(),
          optional(:usage) => map(),
          optional(:metadata) => map(),
          optional(:inserted_at) => DateTime.t()
        }

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @doc "Appends one compact knowledge event."
  @spec append(event(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(event, opts \\ []) when is_map(event) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- Erasure.ensure_durable_write(:knowledge, opts),
         :ok <- validate_event_context(event, opts) do
      call_writer({:append, event, opts}, opts)
    end
  end

  @doc "Appends several compact knowledge events."
  @spec append_many([event()], keyword()) :: {:ok, [pos_integer()]} | {:error, term()}
  def append_many(events, opts \\ []) when is_list(events) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- Erasure.ensure_durable_write(:knowledge, opts),
         :ok <- validate_event_contexts(events, opts) do
      call_writer({:append_many, events, opts}, opts)
    end
  end

  @doc "Replays complete events from `knowledge.smem`."
  @spec replay(keyword()) :: {:ok, [event()]} | {:error, term()}
  def replay(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         {:ok, events} <- opts |> data_root() |> active_path() |> replay_path() do
      visible =
        events
        |> Enum.filter(&Scope.match?(&1, opts))
        |> apply_erasure_marker()
        |> apply_durable_erasure_marker(opts)

      {:ok, visible}
    end
  end

  @spec apply_erasure_marker([event()]) :: [event()]
  defp apply_erasure_marker(events) do
    marker =
      events
      |> Enum.filter(&erasure_marker?/1)
      |> Enum.max_by(&event_timestamp/1, fn -> nil end)

    case marker do
      nil ->
        events

      marker ->
        marker_time = event_timestamp(marker)
        Enum.reject(events, &(erasure_marker?(&1) or event_timestamp(&1) <= marker_time))
    end
  end

  @spec erasure_marker?(event()) :: boolean()
  defp erasure_marker?(event) do
    metadata = Map.get(event, :metadata, %{})
    Map.get(event, :type) == :compaction_marker and Map.get(metadata, :erasure?, false)
  end

  @spec event_timestamp(event()) :: integer()
  defp event_timestamp(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp event_timestamp(_event), do: 0

  @spec apply_durable_erasure_marker([event()], keyword()) :: [event()]
  defp apply_durable_erasure_marker(events, opts) do
    case Erasure.marker(opts) do
      marker when is_map(marker) ->
        cutoff = marker |> map_value(:erased_at) |> datetime_timestamp()
        Enum.filter(events, &(event_timestamp(&1) > cutoff))

      _missing ->
        events
    end
  end

  @spec datetime_timestamp(term()) :: integer()
  defp datetime_timestamp(%DateTime{} = datetime),
    do: DateTime.to_unix(datetime, :microsecond)

  defp datetime_timestamp(_datetime), do: 0

  @spec map_value(map(), atom()) :: term()
  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  @doc "Reduces complete framed events from `knowledge.smem` without loading the whole file."
  @spec reduce(keyword(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(opts \\ [], acc, fun) when is_function(fun, 2) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      root = data_root(opts)
      reduce_path(active_path(root), acc, &reduce_scoped_frame(&1, &2, opts, fun))
    end
  end

  @doc false
  @spec reduce_all(keyword(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce_all(opts, acc, fun) when is_list(opts) and is_function(fun, 2) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      root = data_root(opts)
      reduce_path(active_path(root), acc, &reduce_all_frame(&1, &2, opts, fun))
    end
  end

  @spec reduce_all_frame(tuple(), acc, keyword(), (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:cont, acc} | {:halt, acc}
        when acc: term()
  defp reduce_all_frame({_seq, _timestamp, event} = frame, current, opts, fun) do
    if Scope.match_namespace?(event, opts),
      do: fun.(frame, current),
      else: {:cont, current}
  end

  @doc false
  @spec verify_erased(keyword()) :: :ok | {:error, term()}
  def verify_erased(opts) do
    case reduce(opts, [], &collect_knowledge_survivor/2) do
      {:ok, []} ->
        :ok

      {:ok, survivors} ->
        {:error, {:knowledge_erasure_bytes_survived, Enum.map(survivors, & &1.id)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec collect_knowledge_survivor(tuple(), [event()]) :: {:cont, [event()]}
  defp collect_knowledge_survivor({_sequence, _timestamp, event}, acc) do
    if erasure_marker?(event), do: {:cont, acc}, else: {:cont, [event | acc]}
  end

  @spec reduce_scoped_frame(tuple(), term(), keyword(), function()) ::
          {:cont, term()} | {:halt, term()}
  defp reduce_scoped_frame({_seq, _timestamp, event} = frame, acc, opts, fun) do
    if Scope.match?(event, opts), do: fun.(frame, acc), else: {:cont, acc}
  end

  @doc "Rewrites `knowledge.smem` with a compact replacement event set."
  @spec replace([event()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def replace(events, opts \\ []) when is_list(events) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- Erasure.ensure_durable_write(:knowledge, opts),
         :ok <- validate_event_contexts(events, opts) do
      call_writer({:replace, events, opts}, opts)
    end
  end

  @impl GenServer
  def handle_call({:append, event, opts}, _from, state) do
    {:reply, execute_write({:append, event, opts}), state}
  end

  def handle_call({:append_many, events, opts}, _from, state) do
    {:reply, execute_write({:append_many, events, opts}), state}
  end

  def handle_call({:replace, events, opts}, _from, state) do
    {:reply, execute_write({:replace, events, opts}), state}
  end

  @spec execute_write(term()) :: term()
  defp execute_write({:append, event, opts}),
    do: safe_write(fn -> do_append(event, opts) end)

  defp execute_write({:append_many, events, opts}),
    do: safe_write(fn -> Result.collect_ok(events, &do_append(&1, opts)) end)

  defp execute_write({:replace, events, opts}),
    do: safe_write(fn -> do_replace(events, opts) end)

  @spec do_append(event(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp do_append(event, opts) do
    root = data_root(opts)
    path = active_path(root)
    event = normalize_event(event, opts)

    with :ok <- ensure_root(root),
         {:ok, seq, counter} <- next_seq(path, opts),
         {:ok, sequence} <- write_event(path, event, seq, counter, opts),
         :ok <- Projection.upsert(event, opts) do
      {:ok, sequence}
    end
  end

  @spec do_replace([event()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp do_replace(events, opts) do
    # Replace writes a temp file first because compact knowledge should not
    # vanish halfway through a rewrite. I like boring file moves. They pay rent.
    root = data_root(opts)
    path = active_path(root)
    tmp_path = path <> ".tmp"

    with :ok <- ensure_root(root),
         {:ok, _scan} <- FramedLog.recover_tail(path, Keyword.put(opts, :magic, @magic)),
         {:ok, existing} <- replay_path(path),
         replacement <- replacement_events(existing, events, opts),
         {:ok, frames} <- encode_events(replacement),
         :ok <- FramedLog.write_file(tmp_path, frames, opts),
         :ok <- FramedLog.rename(tmp_path, path, opts) do
      reset_seq(path)
      :ok = Projection.rebuild(opts)
      {:ok, length(events)}
    else
      {:error, reason} ->
        FramedLog.remove(tmp_path, opts)
        {:error, reason}
    end
  end

  @spec replacement_events([event()], [event()], keyword()) :: [event()]
  defp replacement_events(existing, events, opts) do
    preserved = Enum.reject(existing, &Scope.match?(&1, opts))
    preserved ++ Enum.map(events, &normalize_event(&1, opts))
  end

  @doc "Returns the configured knowledge directory."
  @spec data_root(keyword()) :: Path.t()
  def data_root(opts \\ []) do
    root =
      Keyword.get(opts, :data_root) ||
        Application.get_env(:spectre_mnemonic, :data_root, "mnemonic_data")

    Path.join(root, "knowledge")
  end

  @doc "Returns the full `knowledge.smem` path."
  @spec path(keyword()) :: Path.t()
  def path(opts \\ []), do: active_path(data_root(opts))

  @spec event_types :: [event_type()]
  def event_types, do: @event_types

  @spec normalize_event(map(), keyword()) :: event()
  def normalize_event(event, opts \\ []) do
    # Compact events come from people, adapters, and tests with opinions. Clamp
    # the shape here before the tiny knowledge log becomes a junk drawer.
    event = atomize_known_keys(event)
    now = DateTime.utc_now()
    type = event |> Map.get(:type, :fact) |> normalize_type()
    namespace = Identity.namespace!(opts)

    scope =
      if Keyword.has_key?(opts, :scope),
        do: Keyword.get(opts, :scope),
        else: Map.get(event, :scope)

    event_namespace = Map.get(event, :namespace)

    if event_namespace not in [nil, namespace] do
      raise ArgumentError,
            "knowledge event namespace #{inspect(event_namespace)} does not match #{inspect(namespace)}"
    end

    %{
      id: Map.get(event, :id) || Identity.generate("know_evt", opts),
      namespace: namespace,
      scope: scope,
      type: type,
      text:
        compact_text(Map.get(event, :text) || Map.get(event, :summary) || Map.get(event, :name)),
      summary: compact_text(Map.get(event, :summary)),
      name: compact_text(Map.get(event, :name)),
      steps: List.wrap(Map.get(event, :steps, [])),
      value: Map.get(event, :value),
      source_id: Map.get(event, :source_id),
      usage: Map.new(Map.get(event, :usage, %{})),
      metadata:
        event
        |> Map.get(:metadata, %{})
        |> Map.new()
        |> Identity.put_context(Keyword.put(opts, :scope, scope)),
      inserted_at: Map.get(event, :inserted_at) || now
    }
  end

  @spec encode_events([event()]) :: {:ok, [binary()]} | {:error, term()}
  defp encode_events(events) do
    events
    |> Enum.with_index(1)
    |> Result.collect_ok(fn {event, seq} -> frame(seq, event) end)
  end

  @spec write_event(Path.t(), event(), pos_integer(), :atomics.atomics_ref(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp write_event(path, event, seq, counter, opts) do
    with {:ok, frame} <- frame(seq, event) do
      case FramedLog.append(path, frame, opts) do
        :ok ->
          :ok = FramedLog.advance_offset(counter, byte_size(frame))
          {:ok, seq}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec frame(pos_integer(), event()) ::
          {:ok, binary()} | {:error, term()}
  defp frame(seq, event) do
    FileFrame.encode_checked(seq, event, System.system_time(:millisecond),
      magic: @magic,
      version: @version
    )
  end

  @spec ensure_root(Path.t()) :: :ok | {:error, term()}
  defp ensure_root(root), do: File.mkdir_p(root)

  @spec active_path(Path.t()) :: Path.t()
  defp active_path(root), do: Path.join(root, "knowledge.smem")

  @spec next_seq(Path.t(), keyword()) ::
          {:ok, pos_integer(), :atomics.atomics_ref()} | {:error, term()}
  defp next_seq(path, opts) do
    key = {__MODULE__, :seq, path}
    recovery_opts = Keyword.put(opts, :magic, @magic)

    with {:ok, counter} <- FramedLog.sequence_counter(key, path, recovery_opts) do
      {:ok, :atomics.add_get(counter, 1, 1), counter}
    end
  end

  @spec reset_seq(Path.t()) :: :ok
  defp reset_seq(path) do
    FramedLog.reset_sequence_counter({__MODULE__, :seq, path})
  end

  @spec replay_path(Path.t()) :: {:ok, [event()]} | {:error, term()}
  defp replay_path(path) do
    with {:ok, events} <-
           reduce_path(path, [], fn {_seq, _timestamp, event}, acc -> {:cont, [event | acc]} end) do
      {:ok, Enum.reverse(events)}
    end
  end

  @spec reduce_path(Path.t(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp reduce_path(path, acc, fun) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          {:ok, FileFrame.read_frames(io, acc, fun, magic: @magic, version: @version)}
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, known_key(key), value)
    end)
  end

  @spec known_key(term()) :: term()
  defp known_key(key) when is_binary(key), do: Map.get(@event_key_by_string, key, key)
  defp known_key(key), do: key

  @spec normalize_type(term()) :: event_type()
  defp normalize_type(type) when type in @event_types, do: type

  defp normalize_type(type) when is_binary(type) do
    normalized =
      type
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Map.get(@event_type_by_string, normalized, :fact)
  end

  defp normalize_type(_type), do: :fact

  @spec validate_event_contexts([event()], keyword()) :: :ok | {:error, term()}
  defp validate_event_contexts(events, opts) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case validate_event_context(event, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec validate_event_context(event(), keyword()) :: :ok | {:error, term()}
  defp validate_event_context(event, opts) when is_map(event) do
    namespace = Identity.namespace!(opts)
    event = atomize_known_keys(event)

    scope =
      if Keyword.has_key?(opts, :scope), do: Keyword.get(opts, :scope), else: Scope.scope(event)

    Scope.validate_context(event, namespace, scope)
  end

  defp validate_event_context(_event, _opts), do: {:error, :invalid_knowledge_event}

  @spec compact_text(term()) :: binary() | nil
  defp compact_text(nil), do: nil

  defp compact_text(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.slice(0, @max_text_graphemes)
  end

  defp compact_text(text) do
    text
    |> inspect(limit: 50)
    |> compact_text()
  end

  @spec call_writer(term(), keyword()) :: term()
  defp call_writer(message, opts) do
    case Keyword.get(opts, :engine_ref) do
      %SpectreMnemonic.Engine.Ref{} = ref ->
        path = path(opts)

        StoreWriter.trans(
          {__MODULE__, ref, path},
          fn -> execute_write(message) end,
          opts
        )

      _legacy_or_direct ->
        call_default_writer(message, opts)
    end
  end

  @spec call_default_writer(term(), keyword()) :: term()
  defp call_default_writer(message, opts) do
    case Engine.resolve(SpectreMnemonic.DefaultEngine) do
      {:ok, runtime} ->
        path = path(opts)

        StoreWriter.trans(
          {__MODULE__, runtime.config.ref, path},
          fn -> execute_write(message) end,
          Keyword.put(opts, :engine_ref, runtime.config.ref)
        )

      {:error, _reason} ->
        {:error, :knowledge_writer_not_started}
    end
  end

  @spec safe_write((-> result)) :: result | {:error, term()} when result: term()
  defp safe_write(fun) do
    fun.()
  rescue
    exception ->
      {:error, {:knowledge_write_failed, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:knowledge_write_failed, kind, reason}}
  end
end
