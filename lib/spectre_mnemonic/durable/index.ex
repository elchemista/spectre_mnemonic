defmodule SpectreMnemonic.Durable.Index do
  @moduledoc """
  Rebuildable local hybrid index for durable memory records.

  The append-only persistent store remains the source of truth. This process
  keeps derived BM25/vector state for fast local durable search.
  """

  use GenServer

  require Logger

  alias SpectreMnemonic.Durable.Documents
  alias SpectreMnemonic.Durable.Generation
  alias SpectreMnemonic.Durable.Query
  alias SpectreMnemonic.Durable.Rebuild
  alias SpectreMnemonic.Durable.Stats
  alias SpectreMnemonic.Engine
  alias SpectreMnemonic.Engine.Config
  alias SpectreMnemonic.Engine.Ref
  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Persistence.FramedLog
  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Record
  alias SpectreMnemonic.SearchResult
  alias SpectreMnemonic.Telemetry

  @registry SpectreMnemonic.Engine.Registry

  @type doc :: map()

  @doc "Starts the durable search index."
  @spec start_link(keyword() | Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  @spec child_spec(keyword() | Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: {__MODULE__, config.ref},
      start: {__MODULE__, :start_link, [config]}
    }
  end

  def child_spec(opts) when is_list(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Adds or replaces one durable record in the derived index."
  @spec upsert(Record.t()) :: :ok
  def upsert(%Record{} = record),
    do: call_if_running(server_for_namespace(record.namespace), {:upsert, record})

  def upsert(_record), do: :ok

  @doc "Searches durable memory with local hybrid scoring."
  @spec search(term(), keyword()) :: {:ok, [SearchResult.t()]}
  def search(cue, opts \\ []) do
    case search_diagnosed(cue, opts) do
      {:ok, results} -> {:ok, results}
      {:error, _reason} -> {:ok, []}
    end
  end

  @doc false
  @spec search_diagnosed(term(), keyword()) ::
          {:ok, [SearchResult.t()]} | {:error, term()}
  def search_diagnosed(cue, opts \\ []) do
    case server_for_opts(opts) do
      nil ->
        {:error, :durable_index_unavailable}

      pid ->
        case GenServer.call(pid, {:search_candidates, cue, opts}) do
          snapshot when is_map(snapshot) -> {:ok, Query.search(snapshot, cue, opts)}
          _invalid -> {:error, :durable_index_unavailable}
        end
    end
  rescue
    exception ->
      Logger.warning(
        "durable index search failed exception=#{inspect(exception.__struct__)} " <>
          "reason=#{Exception.message(exception)}"
      )

      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning(
        "durable index search failed kind=#{inspect(kind)} reason=#{inspect(reason)}"
      )

      {:error, {kind, reason}}
  end

  @doc false
  @spec status(binary() | :all) :: map()
  def status(namespace \\ :all)
  def status(:all), do: aggregate_status()

  def status(namespace) do
    case server_for_namespace(namespace) do
      nil ->
        %{
          running?: false,
          documents: 0,
          generation: nil,
          rebuilding?: false,
          last_rebuild_at: nil
        }

      pid ->
        GenServer.call(pid, {:status, namespace})
    end
  catch
    :exit, _reason ->
      %{
        running?: false,
        documents: 0,
        generation: nil,
        rebuilding?: false,
        last_rebuild_at: nil
      }
  end

  @doc "Rebuilds the index from persistent replay."
  @spec rebuild(keyword()) :: :ok | {:error, term()}
  def rebuild(opts \\ []) do
    Telemetry.span([:rebuild], Telemetry.metadata(opts), fn ->
      rebuild_server(server_for_opts(opts), opts)
    end)
  catch
    :exit, reason -> {:error, {:durable_index_rebuild_failed, reason}}
  end

  defp rebuild_server(nil, _opts), do: :ok

  defp rebuild_server(pid, opts) do
    case GenServer.call(pid, :begin_rebuild) do
      {:ok, ref, runtime_opts} -> run_rebuild(pid, ref, rebuild_opts(runtime_opts, opts))
      {:error, _reason} = error -> error
    end
  end

  defp run_rebuild(pid, ref, opts) do
    case Rebuild.build_stream(opts) do
      {:ok, rebuilt} -> finish_successful_rebuild(pid, ref, rebuilt)
      {:error, reason} -> GenServer.call(pid, {:finish_rebuild, ref, {:error, reason}})
    end
  end

  defp finish_successful_rebuild(pid, ref, rebuilt) do
    transfer_tables(rebuilt.tables, pid, ref)
    GenServer.call(pid, {:finish_rebuild, ref, {:ok, rebuilt}})
  end

  @doc "Clears all derived index state."
  @spec reset :: :ok
  def reset do
    index_servers()
    |> Enum.each(&safe_call(&1, :reset))

    if pid = Process.whereis(__MODULE__), do: safe_call(pid, :reset)
    :ok
  end

  @doc false
  @spec server(keyword() | binary() | Ref.t()) :: pid() | nil
  def server(%Ref{} = ref), do: server_for_ref(ref)
  def server(namespace) when is_binary(namespace), do: server_for_namespace(namespace)
  def server(opts) when is_list(opts), do: server_for_opts(opts)

  @doc false
  @spec purge_legacy_snapshot(keyword()) :: :ok | {:error, term()}
  def purge_legacy_snapshot(opts \\ []) do
    FramedLog.remove(snapshot_path(opts), Keyword.put_new(opts, :sync, :always))
  end

  @impl GenServer
  @spec init(keyword() | Config.t()) :: {:ok, map()} | {:stop, term()}
  def init(%Config{} = config) do
    opts = engine_opts(config)
    _result = purge_legacy_snapshot(opts)

    case Registry.register(@registry, {:durable_index, config.ref}, nil) do
      {:ok, _owner} ->
        send(self(), {:rebuild, opts})
        {:ok, Documents.empty_state() |> Map.put(:runtime_opts, opts)}

      {:error, {:already_registered, pid}} ->
        {:stop, {:durable_index_already_started, config.ref, pid}}
    end
  end

  def init(opts) when is_list(opts) do
    _result = purge_legacy_snapshot(opts)
    send(self(), {:rebuild, opts})
    {:ok, Documents.empty_state() |> Map.put(:runtime_opts, opts)}
  end

  @impl GenServer
  def handle_info({:rebuild, opts}, state) do
    case Rebuild.build_stream(opts) do
      {:ok, rebuilt} ->
        {:noreply, install_rebuild(state, rebuilt, [])}

      {:error, reason} ->
        Logger.warning("durable index rebuild failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{rebuild: %{monitor: monitor}} = state
      ) do
    {:noreply, Generation.owner_down(state, monitor)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, Generation.owner_down(state, monitor)}

  def handle_info(
        {:"ETS-TRANSFER", table, _from, {:durable_rebuild, ref, name}},
        state
      ) do
    case state.rebuild do
      %{ref: ^ref} ->
        {:noreply, Generation.track_transfer(state, ref, name, table)}

      _stale_or_finished ->
        delete_if_inactive(table, state)
        {:noreply, state}
    end
  end

  def handle_info({:"ETS-TRANSFER", table, _from, _gift}, state) do
    delete_if_inactive(table, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:begin_rebuild, {caller, _tag}, %{rebuild: nil} = state) do
    {{:ok, ref}, state} = Generation.begin(state, caller)
    {:reply, {:ok, ref, state.runtime_opts}, state}
  end

  def handle_call(:begin_rebuild, _from, state),
    do: {:reply, {:error, :rebuild_in_progress}, state}

  def handle_call({:finish_rebuild, ref, {:ok, rebuilt}}, _from, state) do
    case Generation.complete(state, ref) do
      {:ok, pending, state} ->
        {:reply, :ok, install_rebuild(state, rebuilt, pending)}

      {:error, :stale_rebuild} ->
        Documents.destroy(rebuilt)
        {:reply, {:error, :stale_rebuild}, state}
    end
  end

  def handle_call({:finish_rebuild, ref, {:error, reason}}, _from, state) do
    case Generation.fail(state, ref) do
      {:ok, state} ->
        {:reply, {:error, reason}, state}

      {:error, :stale_rebuild} ->
        {:reply, {:error, :stale_rebuild}, state}
    end
  end

  def handle_call({:upsert, record}, _from, state) do
    state = state |> Documents.upsert(record) |> Generation.track(record)
    {:reply, :ok, state}
  end

  def handle_call({:search_candidates, cue, opts}, _from, state) do
    state = Stats.ensure(state)
    snapshot = Query.candidate_snapshot(state, cue, opts)
    {:reply, snapshot, state}
  end

  def handle_call({:status, namespace}, _from, state) do
    documents = Documents.count_namespace(state, namespace)

    status = %{
      running?: true,
      documents: documents,
      generation: state.revision,
      rebuilding?: not is_nil(state.rebuild),
      last_rebuild_at: state.last_rebuild_at
    }

    {:reply, status, state}
  end

  def handle_call(:reset, _from, state) do
    state = Documents.reset(state)
    _result = purge_legacy_snapshot([])
    {:reply, :ok, state}
  end

  defp install_rebuild(state, rebuilt, pending) do
    runtime_opts = state.runtime_opts
    revision = state.revision + 1
    rebuilt = Documents.index_records(rebuilt, pending)

    rebuilt =
      rebuilt
      |> Map.put(:runtime_opts, runtime_opts)
      |> Map.merge(%{
        dirty?: false,
        revision: revision,
        stats_revision: revision,
        last_rebuild_at: DateTime.utc_now(),
        rebuild: nil
      })
      |> Documents.sync_metadata()

    :ok = Documents.destroy(state)
    rebuilt
  end

  @spec snapshot_path(keyword()) :: Path.t()
  defp snapshot_path(opts) do
    root =
      Keyword.get(opts, :data_root) ||
        Application.get_env(:spectre_mnemonic, :data_root, StoreFile.data_root())

    Path.join([root, "index", "durable.term"])
  end

  @spec engine_opts(Config.t()) :: keyword()
  defp engine_opts(config) do
    [
      engine_ref: config.ref,
      engine_internal?: true,
      storage_id: config.storage_id,
      namespace: config.internal_namespace,
      data_root: config.data_root,
      persistent_memory: config.persistent_memory,
      embedding_space: config.embedding_space,
      max_candidates: config.limits.max_candidates
    ]
  end

  @spec transfer_tables(Documents.tables(), pid(), reference()) :: :ok
  defp transfer_tables(tables, pid, ref) do
    Enum.each(tables, fn {name, table} ->
      true = :ets.give_away(table, pid, {:durable_rebuild, ref, name})
    end)

    :ok
  end

  defp delete_if_inactive(table, state) do
    if table not in Map.values(state.tables) and :ets.info(table, :owner) == self() do
      :ets.delete(table)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec rebuild_opts(keyword(), keyword()) :: keyword()
  defp rebuild_opts(runtime_opts, call_opts) do
    explicit_engine? =
      Keyword.has_key?(call_opts, :engine) or Keyword.has_key?(call_opts, :engine_ref)

    if explicit_engine? do
      call_opts =
        Keyword.drop(call_opts, [
          :persistent_memory,
          :data_root,
          :namespace,
          :storage_id,
          :embedding_space
        ])

      Keyword.merge(runtime_opts, call_opts)
    else
      runtime_opts
      |> Keyword.take([:engine_ref, :engine_internal?, :namespace, :storage_id])
      |> Keyword.merge(call_opts)
    end
  end

  @spec server_for_opts(keyword()) :: pid() | nil
  defp server_for_opts(opts) do
    case Keyword.get(opts, :engine_ref) do
      %Ref{} = ref -> server_for_ref(ref)
      _missing -> opts |> Identity.fetch_namespace() |> server_from_namespace_result()
    end || Process.whereis(__MODULE__)
  end

  @spec server_from_namespace_result({:ok, binary()} | {:error, term()}) :: pid() | nil
  defp server_from_namespace_result({:ok, namespace}), do: server_for_namespace(namespace)
  defp server_from_namespace_result({:error, _reason}), do: nil

  @spec server_for_namespace(term()) :: pid() | nil
  defp server_for_namespace(namespace) when is_binary(namespace) do
    case Engine.resolve_internal_namespace(namespace) do
      {:ok, runtime} -> server_for_ref(runtime.config.ref)
      {:error, _reason} -> nil
    end
  end

  defp server_for_namespace(_namespace), do: nil

  @spec server_for_ref(Ref.t()) :: pid() | nil
  defp server_for_ref(%Ref{} = ref) do
    case Registry.lookup(@registry, {:durable_index, ref}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec index_servers :: [pid()]
  defp index_servers do
    @registry
    |> Registry.select([{{{:durable_index, :"$1"}, :"$2", :_}, [], [:"$2"]}])
    |> Enum.uniq()
  rescue
    ArgumentError -> []
  end

  @spec aggregate_status :: map()
  defp aggregate_status do
    statuses = Enum.map(index_servers(), &safe_status/1)

    %{
      running?: statuses != [] and Enum.all?(statuses, & &1.running?),
      documents: Enum.sum(Enum.map(statuses, & &1.documents)),
      generation:
        Map.new(Enum.with_index(statuses), fn {status, index} -> {index, status.generation} end),
      rebuilding?: Enum.any?(statuses, & &1.rebuilding?),
      last_rebuild_at:
        statuses
        |> Enum.map(& &1.last_rebuild_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
    }
  end

  @spec safe_status(pid()) :: map()
  defp safe_status(pid) do
    GenServer.call(pid, {:status, :all})
  catch
    :exit, _reason ->
      %{running?: false, documents: 0, generation: nil, rebuilding?: false, last_rebuild_at: nil}
  end

  @spec safe_call(pid(), term()) :: :ok
  defp safe_call(pid, message) do
    _reply = GenServer.call(pid, message)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec call_if_running(pid() | nil, term(), term()) :: term()
  defp call_if_running(pid, message, default \\ :ok) do
    case pid do
      nil -> default
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> default
  end
end
