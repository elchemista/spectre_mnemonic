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
  @header_bytes byte_size(@magic) + 1 + 8 + 8 + 4 + 4
  @max_text_graphemes 2_000

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
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
         :ok <- validate_event_context(event, opts) do
      call_writer({:append, event, opts})
    end
  end

  @doc "Appends several compact knowledge events."
  @spec append_many([event()], keyword()) :: {:ok, [pos_integer()]} | {:error, term()}
  def append_many(events, opts \\ []) when is_list(events) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- validate_event_contexts(events, opts) do
      call_writer({:append_many, events, opts})
    end
  end

  @doc "Replays complete events from `knowledge.smem`."
  @spec replay(keyword()) :: {:ok, [event()]}
  def replay(opts \\ []) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      root = data_root(opts)

      events =
        root
        |> active_path()
        |> replay_path()
        |> Enum.filter(&Scope.match?(&1, opts))

      {:ok, events}
    end
  end

  @doc "Reduces complete framed events from `knowledge.smem` without loading the whole file."
  @spec reduce(keyword(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(opts \\ [], acc, fun) when is_function(fun, 2) do
    with {:ok, opts} <- Identity.put_namespace(opts) do
      root = data_root(opts)

      reduce_path(active_path(root), acc, fn {_seq, _timestamp, event} = frame, acc ->
        if Scope.match?(event, opts), do: fun.(frame, acc), else: {:cont, acc}
      end)
    end
  end

  @doc "Rewrites `knowledge.smem` with a compact replacement event set."
  @spec replace([event()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def replace(events, opts \\ []) when is_list(events) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         :ok <- validate_event_contexts(events, opts) do
      call_writer({:replace, events, opts})
    end
  end

  @impl GenServer
  def handle_call({:append, event, opts}, _from, state) do
    {:reply, do_append(event, opts), state}
  end

  def handle_call({:append_many, events, opts}, _from, state) do
    result = Result.collect_ok(events, &do_append(&1, opts))
    {:reply, result, state}
  end

  def handle_call({:replace, events, opts}, _from, state) do
    {:reply, do_replace(events, opts), state}
  end

  @spec do_append(event(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp do_append(event, opts) do
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    write_event(path, event, next_seq(path), opts)
  end

  @spec do_replace([event()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp do_replace(events, opts) do
    # Replace writes a temp file first because compact knowledge should not
    # vanish halfway through a rewrite. I like boring file moves. They pay rent.
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    tmp_path = path <> ".tmp"
    preserved = path |> replay_path() |> Enum.reject(&Scope.match?(&1, opts))
    replacement = preserved ++ Enum.map(events, &normalize_event(&1, opts))

    with :ok <- File.write(tmp_path, "", [:binary]),
         {:ok, _seqs} <- append_many_to_path(tmp_path, replacement),
         :ok <- File.rename(tmp_path, path) do
      reset_seq(path)
      {:ok, length(events)}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
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
    scope = if Keyword.has_key?(opts, :scope), do: Keyword.get(opts, :scope), else: Map.get(event, :scope)
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

  @spec append_many_to_path(Path.t(), [event()]) ::
          {:ok, [pos_integer()]} | {:error, term()}
  defp append_many_to_path(path, events) do
    events
    |> Enum.with_index(1)
    |> Result.collect_ok(fn {event, seq} -> write_normalized_event(path, event, seq) end)
  end

  @spec write_event(Path.t(), event(), pos_integer(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp write_event(path, event, seq, opts) do
    event = normalize_event(event, opts)
    write_normalized_event(path, event, seq)
  end

  @spec write_normalized_event(Path.t(), event(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp write_normalized_event(path, event, seq) do
    case File.write(path, frame(seq, event), [:append, :binary]) do
      :ok -> {:ok, seq}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec frame(pos_integer(), event()) :: binary()
  defp frame(seq, event) do
    payload = :erlang.term_to_binary(event, [:compressed])
    crc = :erlang.crc32(payload)
    timestamp = System.system_time(:millisecond)

    <<@magic, @version, seq::unsigned-64, timestamp::signed-64, byte_size(payload)::32, crc::32,
      payload::binary>>
  end

  @spec ensure_root!(Path.t()) :: :ok
  defp ensure_root!(root), do: File.mkdir_p!(root)

  @spec active_path(Path.t()) :: Path.t()
  defp active_path(root), do: Path.join(root, "knowledge.smem")

  @spec next_seq(Path.t()) :: pos_integer()
  defp next_seq(path) do
    key = {__MODULE__, :seq, path}

    current =
      case :persistent_term.get(key, :missing) do
        :missing -> initial_seq(path)
        seq -> seq
      end

    seq = current + 1
    :persistent_term.put(key, seq)
    seq
  end

  @spec reset_seq(Path.t()) :: :ok
  defp reset_seq(path) do
    :persistent_term.put({__MODULE__, :seq, path}, initial_seq(path))
    :ok
  end

  @spec initial_seq(Path.t()) :: non_neg_integer()
  defp initial_seq(path) do
    {:ok, seq} = reduce_path(path, 0, fn {seq, _timestamp, _event}, _acc -> {:cont, seq} end)
    seq
  end

  @spec replay_path(Path.t()) :: [event()]
  defp replay_path(path) do
    {:ok, events} =
      reduce_path(path, [], fn {_seq, _timestamp, event}, acc -> {:cont, [event | acc]} end)

    Enum.reverse(events)
  end

  @spec reduce_path(Path.t(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  defp reduce_path(path, acc, fun) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, read_frames(io, acc, fun)}
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec read_frames(File.io_device(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) :: acc
        when acc: term()
  defp read_frames(io, acc, fun) do
    case IO.binread(io, @header_bytes) do
      <<@magic, @version, seq::unsigned-64, timestamp::signed-64, len::32, crc::32>> ->
        read_payload(io, seq, timestamp, len, crc, acc, fun)

      incomplete_or_unknown when is_binary(incomplete_or_unknown) ->
        acc

      :eof ->
        acc

      {:error, _reason} ->
        acc
    end
  end

  @spec read_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer(),
          acc,
          (tuple(), acc -> {:cont, acc} | {:halt, acc})
        ) :: acc
        when acc: term()
  defp read_payload(io, seq, timestamp, len, crc, acc, fun) do
    case IO.binread(io, len) do
      payload when is_binary(payload) and byte_size(payload) == len ->
        read_complete_payload(io, seq, timestamp, payload, crc, acc, fun)

      _incomplete_or_error ->
        acc
    end
  end

  @spec read_complete_payload(
          File.io_device(),
          pos_integer(),
          integer(),
          binary(),
          non_neg_integer(),
          acc,
          (tuple(), acc -> {:cont, acc} | {:halt, acc})
        ) :: acc
        when acc: term()
  defp read_complete_payload(io, seq, timestamp, payload, crc, acc, fun) do
    if :erlang.crc32(payload) == crc do
      case decode_payload(payload) do
        {:ok, event} -> continue_frame(io, {seq, timestamp, event}, acc, fun)
        :error -> acc
      end
    else
      acc
    end
  end

  @spec decode_payload(binary()) :: {:ok, term()} | :error
  defp decode_payload(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception -> :error
  end

  @spec continue_frame(File.io_device(), tuple(), acc, (tuple(), acc ->
                                                          {:cont, acc} | {:halt, acc})) ::
          acc
        when acc: term()
  defp continue_frame(io, frame, acc, fun) do
    case fun.(frame, acc) do
      {:cont, acc} -> read_frames(io, acc, fun)
      {:halt, acc} -> acc
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
    event_namespace = Map.get(event, :namespace)
    event_scope = Map.get(event, :scope)

    cond do
      event_namespace not in [nil, namespace] ->
        {:error, {:namespace_mismatch, namespace, event_namespace}}

      Keyword.has_key?(opts, :scope) and event_scope not in [nil, Keyword.get(opts, :scope)] ->
        {:error, {:scope_mismatch, Keyword.get(opts, :scope), event_scope}}

      Keyword.has_key?(opts, :scopes) and Keyword.get(opts, :scopes) != :all and
          not is_nil(event_scope) and event_scope not in List.wrap(Keyword.get(opts, :scopes)) ->
        {:error, {:scope_mismatch, Keyword.get(opts, :scopes), event_scope}}

      true ->
        :ok
    end
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

  @spec call_writer(term()) :: term()
  defp call_writer(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :knowledge_writer_not_started}
      _pid -> GenServer.call(__MODULE__, message, 30_000)
    end
  end
end
