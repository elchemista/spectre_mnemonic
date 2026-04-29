defmodule SpectreMnemonic.Knowledge.SMEM do
  @moduledoc """
  Compact append-only knowledge event log.

  The file lives at `data_root/knowledge/knowledge.smem` and uses the same
  framed binary style as the default file store: magic/version bytes, sequence,
  timestamp, payload length, CRC32, and compressed Erlang term payload.
  """

  @magic "SKNW"
  @version 1
  @header_bytes byte_size(@magic) + 1 + 8 + 8 + 4 + 4
  @max_text_graphemes 2_000

  alias SpectreMnemonic.Result

  @event_types [:summary, :skill, :latest_ingestion, :fact, :procedure, :compaction_marker]

  @type event_type ::
          :summary | :skill | :latest_ingestion | :fact | :procedure | :compaction_marker

  @type event :: %{
          optional(:id) => binary(),
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

  @doc "Appends one compact knowledge event."
  @spec append(event(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def append(event, opts \\ []) when is_map(event) do
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    write_event(path, event, next_seq(path))
  end

  @doc "Appends several compact knowledge events."
  @spec append_many([event()], keyword()) :: {:ok, [pos_integer()]} | {:error, term()}
  def append_many(events, opts \\ []) when is_list(events) do
    Result.collect_ok(events, &append(&1, opts))
  end

  @doc "Replays complete events from `knowledge.smem`."
  @spec replay(keyword()) :: {:ok, [event()]}
  def replay(opts \\ []) do
    root = data_root(opts)
    {:ok, replay_path(active_path(root))}
  end

  @doc "Reduces complete framed events from `knowledge.smem` without loading the whole file."
  @spec reduce(keyword(), acc, (tuple(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(opts \\ [], acc, fun) when is_function(fun, 2) do
    root = data_root(opts)
    reduce_path(active_path(root), acc, fun)
  end

  @doc "Rewrites `knowledge.smem` with a compact replacement event set."
  @spec replace([event()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def replace(events, opts \\ []) when is_list(events) do
    root = data_root(opts)
    ensure_root!(root)
    path = active_path(root)
    tmp_path = path <> ".tmp"

    with :ok <- File.write(tmp_path, "", [:binary]),
         {:ok, _seqs} <- append_many_to_path(tmp_path, events),
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

  @spec normalize_event(map()) :: event()
  def normalize_event(event) do
    event = atomize_known_keys(event)
    now = DateTime.utc_now()
    type = event |> Map.get(:type, :fact) |> normalize_type()

    %{
      id: Map.get(event, :id) || id("know_evt"),
      type: type,
      text:
        compact_text(Map.get(event, :text) || Map.get(event, :summary) || Map.get(event, :name)),
      summary: compact_text(Map.get(event, :summary)),
      name: compact_text(Map.get(event, :name)),
      steps: List.wrap(Map.get(event, :steps, [])),
      value: Map.get(event, :value),
      source_id: Map.get(event, :source_id),
      usage: Map.new(Map.get(event, :usage, %{})),
      metadata: Map.new(Map.get(event, :metadata, %{})),
      inserted_at: Map.get(event, :inserted_at) || now
    }
  end

  @spec append_many_to_path(Path.t(), [event()]) :: {:ok, [pos_integer()]} | {:error, term()}
  defp append_many_to_path(path, events) do
    events
    |> Enum.with_index(1)
    |> Result.collect_ok(fn {event, seq} -> write_event(path, event, seq) end)
  end

  @spec write_event(Path.t(), event(), pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  defp write_event(path, event, seq) do
    case File.write(path, frame(seq, event), [:append, :binary]) do
      :ok -> {:ok, seq}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec frame(pos_integer(), event()) :: binary()
  defp frame(seq, event) do
    payload = event |> normalize_event() |> :erlang.term_to_binary([:compressed])
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
      frame = {seq, timestamp, :erlang.binary_to_term(payload)}
      continue_frame(io, frame, acc, fun)
    else
      acc
    end
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
    known = ~w(id type text summary name steps value source_id usage metadata inserted_at)a

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      key =
        if is_binary(key) do
          Enum.find(known, &(Atom.to_string(&1) == key)) || key
        else
          key
        end

      Map.put(acc, key, value)
    end)
  end

  @spec normalize_type(term()) :: event_type()
  defp normalize_type(type) when type in @event_types, do: type

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_existing_atom()
    |> normalize_type()
  rescue
    ArgumentError -> :fact
  end

  defp normalize_type(_type), do: :fact

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

  @spec id(binary()) :: binary()
  defp id(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
end
