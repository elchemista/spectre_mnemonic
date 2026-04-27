defmodule SpectreMnemonic.Router do
  @moduledoc """
  Chooses the stream for incoming signals.

  Routing order follows the plan: explicit `:stream`, then task id, then
  metadata/kind inference, then `:chat`.
  """

  use GenServer

  @doc "Starts the router process."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Routes and records a signal."
  def signal(input, opts) do
    GenServer.call(__MODULE__, {:signal, input, opts})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:signal, input, opts}, _from, state) do
    stream = route(input, opts)

    with {:ok, _pid} <- SpectreMnemonic.StreamSupervisor.ensure_stream(stream) do
      {:reply, SpectreMnemonic.StreamServer.signal(stream, input, opts), state}
    else
      error -> {:reply, error, state}
    end
  end

  defp route(_input, opts) do
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

  defp metadata_stream(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    Map.get(metadata, :stream) || Map.get(metadata, "stream")
  end
end
