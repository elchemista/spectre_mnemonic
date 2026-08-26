defmodule SpectreMnemonic.Recall.Ranker do
  @moduledoc false

  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.QueryContext
  alias SpectreMnemonic.Recall.Features

  @doc false
  @spec rank([map()], QueryContext.t(), map(), non_neg_integer(), keyword()) :: [map()]
  def rank(candidates, cue, index_scores, limit, opts) do
    candidates
    |> Enum.reduce([], fn moment, ranked ->
      score =
        if visible?(moment, opts), do: Features.score(moment, cue, index_scores, opts), else: 0

      if score > 0,
        do: insert({score, moment}, ranked, limit),
        else: ranked
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @doc false
  @spec rerank_fused([{float(), map()}], QueryContext.t(), map()) :: [map()]
  def rerank_fused(fused, cue, index_scores) do
    fused
    |> Enum.uniq_by(fn {_rrf_score, moment} -> moment.id end)
    |> Enum.map(fn {rrf_score, moment} ->
      feature_score =
        max(
          Features.score(moment, cue, index_scores, cue.opts),
          Features.structured_score(moment, cue)
        )

      normalized_feature = Features.normalize(feature_score)
      normalized_rrf = min(1.0, rrf_score * 20.0)
      {normalized_rrf * 0.55 + normalized_feature * 0.45, moment}
    end)
    |> Enum.sort_by(&rank_key/1)
    |> Enum.map(fn {_score, moment} -> moment end)
  end

  @doc false
  @spec filter_visible([map()], keyword()) :: [map()]
  def filter_visible(moments, opts), do: Enum.filter(moments, &visible?(&1, opts))

  @spec visible?(map(), keyword()) :: boolean()
  defp visible?(moment, opts) do
    state_opts = Keyword.put(opts, :scope, Scope.scope(moment))

    Scope.match?(moment, opts) and Temporal.match?(moment, opts) and
      Governance.search_visible?(moment.id, state_opts)
  end

  @spec insert({number(), map()}, [{number(), map()}], non_neg_integer()) ::
          [{number(), map()}]
  defp insert(candidate, ranked, limit) do
    [candidate | ranked]
    |> Enum.sort_by(&rank_key/1)
    |> Enum.take(limit)
  end

  @spec rank_key({number(), map()}) :: {number(), integer()}
  defp rank_key({score, moment}),
    do: {-score, -DateTime.to_unix(moment.inserted_at, :microsecond)}
end
