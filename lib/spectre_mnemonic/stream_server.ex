defmodule SpectreMnemonic.StreamServer do
  @moduledoc """
  Worker for one activity lane.

  V1 records immediately into focus. The process boundary is still useful
  because future stream-specific throttling, batching, or summarization can land
  here without changing the public API.
  """

  use GenServer

  @type state :: %{stream: term()}

  @doc "Starts a stream server registered by stream name."
  @spec start_link(stream :: term()) :: GenServer.on_start()
  def start_link(stream) do
    GenServer.start_link(__MODULE__, stream, name: via(stream))
  end

  @doc "Records input through the stream process."
  @spec signal(stream :: term(), input :: term(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def signal(stream, input, opts) do
    GenServer.call(via(stream), {:signal, input, opts})
  end

  @impl true
  @spec init(stream :: term()) :: {:ok, state()}
  def init(stream) do
    :ets.insert(
      :mnemonic_streams,
      {stream, %{name: stream, status: :active, inserted_at: DateTime.utc_now()}}
    )

    {:ok, %{stream: stream}}
  end

  @impl true
  @spec handle_call({:signal, term(), keyword()}, GenServer.from(), state()) ::
          {:reply, {:ok, map()} | {:error, term()}, state()}
  def handle_call({:signal, input, opts}, _from, %{stream: stream} = state) do
    opts = Keyword.put(opts, :stream, stream)
    {:reply, SpectreMnemonic.Focus.record_signal(input, opts), state}
  end

  @spec via(stream :: term()) :: {:via, Registry, {SpectreMnemonic.StreamRegistry, term()}}
  defp via(stream) do
    {:via, Registry, {SpectreMnemonic.StreamRegistry, stream}}
  end
end
