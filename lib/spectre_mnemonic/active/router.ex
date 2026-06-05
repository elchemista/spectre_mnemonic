defmodule SpectreMnemonic.Active.Router do
  @moduledoc """
  Chooses the stream for incoming signals.

  Routing order follows the plan: explicit `:stream`, then task id, then
  metadata/kind inference, then `:chat`.
  """

  use GenServer

  alias SpectreMnemonic.Active.StreamServer
  alias SpectreMnemonic.Active.StreamSupervisor

  @doc "Starts the router process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Routes and records a signal."
  @spec signal(input :: term(), opts :: keyword()) ::
          {:ok,
           %{signal: SpectreMnemonic.Memory.Signal.t(), moment: SpectreMnemonic.Memory.Moment.t()}}
          | {:error, term()}
  def signal(input, opts) do
    GenServer.call(__MODULE__, {:signal, input, opts})
  end

  @impl GenServer
  @spec init(map()) :: {:ok, map()}
  def init(state), do: {:ok, state}

  @impl GenServer
  @spec handle_call({:signal, term(), keyword()}, GenServer.from(), map()) ::
          {:reply, term(), map()}
  def handle_call({:signal, input, opts}, _from, state) do
    stream = route(input, opts)

    case StreamSupervisor.ensure_stream(stream) do
      {:ok, _pid} -> {:reply, StreamServer.signal(stream, input, opts), state}
      error -> {:reply, error, state}
    end
  end

  @spec route(term(), keyword()) :: term()
  defp route(_input, opts) do
    # Routing is intentionally dumb and inspectable. Explicit stream wins,
    # task lanes come next, and only then do we infer. Future me may add policy,
    # but today I want to know where the memory went without reading tea leaves.
    cond do
      Keyword.get(opts, :stream) ->
        Keyword.fetch!(opts, :stream)

      Keyword.get(opts, :task_id) ->
        {:task, Keyword.fetch!(opts, :task_id)}

      stream = metadata_stream(opts) ->
        stream

      Keyword.get(opts, :kind) in [:research, :code_learning, :task_execution, :tool] ->
        Keyword.fetch!(opts, :kind)

      true ->
        :chat
    end
  end

  @spec metadata_stream(keyword()) :: term() | nil
  defp metadata_stream(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    Map.get(metadata, :stream) || Map.get(metadata, "stream")
  end
end
