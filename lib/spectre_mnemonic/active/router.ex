defmodule SpectreMnemonic.Active.Router do
  @moduledoc """
  Statelessly chooses the stream for incoming signals.

  Routing order follows the plan: explicit `:stream`, then task id, then
  metadata/kind inference, then `:chat`.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Engine.Limits
  alias SpectreMnemonic.Identity

  @doc "Routes and records a signal."
  @spec signal(input :: term(), opts :: keyword()) ::
          {:ok,
           %{signal: SpectreMnemonic.Memory.Signal.t(), moment: SpectreMnemonic.Memory.Moment.t()}}
          | {:error, term()}
  def signal(input, opts) do
    with :ok <- Limits.validate_input(input, opts),
         {:ok, opts} <- Identity.put_namespace(opts) do
      Focus.record_signal(input, Keyword.put(opts, :stream, route(input, opts)))
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
    metadata = normalize_metadata(Keyword.get(opts, :metadata, %{}))
    Map.get(metadata, :stream) || Map.get(metadata, "stream")
  end

  @spec normalize_metadata(term()) :: map()
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata), do: Map.new(metadata), else: %{}
  end

  defp normalize_metadata(_metadata), do: %{}
end
