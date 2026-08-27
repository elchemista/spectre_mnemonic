defmodule SpectreMnemonic.Recall.Packet do
  @moduledoc """
  Neighborhood returned by `SpectreMnemonic.recall/2`.
  """

  @type t :: %__MODULE__{
          cue: SpectreMnemonic.QueryContext.t(),
          query_context: SpectreMnemonic.QueryContext.t(),
          search_results: [SpectreMnemonic.SearchResult.t()],
          active_status: [map()],
          moments: [SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()],
          observations: [SpectreMnemonic.Memory.Observation.t()],
          mental_models: [SpectreMnemonic.Memory.MentalModel.t()],
          episodes: [SpectreMnemonic.Memory.Episode.t()],
          knowledge: [SpectreMnemonic.Knowledge.Record.t()],
          artifacts: [SpectreMnemonic.Memory.Artifact.t()],
          associations: [SpectreMnemonic.Memory.Association.t()],
          action_recipes: [SpectreMnemonic.Memory.ActionRecipe.t()],
          trace: %{optional(binary()) => map()} | nil,
          confidence: float(),
          diagnostics: map(),
          usage: map()
        }

  defstruct [
    :cue,
    :query_context,
    search_results: [],
    active_status: [],
    moments: [],
    observations: [],
    mental_models: [],
    episodes: [],
    knowledge: [],
    artifacts: [],
    associations: [],
    action_recipes: [],
    trace: nil,
    confidence: 0.0,
    diagnostics: %{},
    usage: %{}
  ]
end
