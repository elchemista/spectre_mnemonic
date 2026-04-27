defmodule SpectreMnemonic.StreamSupervisor do
  @moduledoc "Dynamic supervisor for per-stream worker processes."

  use DynamicSupervisor

  @doc "Starts the stream supervisor."
  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Ensures a stream server exists for a stream name."
  def ensure_stream(stream) do
    spec = {SpectreMnemonic.StreamServer, stream}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

defmodule SpectreMnemonic.StreamServer do
  @moduledoc """
  Worker for one activity lane.

  V1 records immediately into focus. The process boundary is still useful
  because future stream-specific throttling, batching, or summarization can land
  here without changing the public API.
  """

  use GenServer

  @doc "Starts a stream server registered by stream name."
  def start_link(stream) do
    GenServer.start_link(__MODULE__, stream, name: via(stream))
  end

  @doc "Records input through the stream process."
  def signal(stream, input, opts) do
    GenServer.call(via(stream), {:signal, input, opts})
  end

  @impl true
  def init(stream) do
    :ets.insert(
      :mnemonic_streams,
      {stream, %{name: stream, status: :active, inserted_at: DateTime.utc_now()}}
    )

    {:ok, %{stream: stream}}
  end

  @impl true
  def handle_call({:signal, input, opts}, _from, %{stream: stream} = state) do
    opts = Keyword.put(opts, :stream, stream)
    {:reply, SpectreMnemonic.Focus.record_signal(input, opts), state}
  end

  defp via(stream) do
    {:via, Registry, {SpectreMnemonic.StreamRegistry, stream}}
  end
end
