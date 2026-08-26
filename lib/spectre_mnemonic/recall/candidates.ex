defmodule SpectreMnemonic.Recall.Candidates do
  @moduledoc false

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Engine.Projection
  alias SpectreMnemonic.QueryContext

  @doc false
  @spec collect(QueryContext.t(), [binary()], keyword()) :: {[map()], Projection.candidate_meta()}
  def collect(cue, vector_ids, opts) do
    case Projection.candidates(cue, vector_ids, opts) do
      {:ok, moments, meta} ->
        {moments, meta}

      {:fallback, meta} ->
        {Focus.fold_moments([], fn moment, acc -> [moment | acc] end, opts), meta}
    end
  end

  @doc false
  @spec empty_meta :: Projection.candidate_meta()
  def empty_meta, do: %{total: 0, candidates: 0, mode: :candidate_first, sources: %{}}
end
