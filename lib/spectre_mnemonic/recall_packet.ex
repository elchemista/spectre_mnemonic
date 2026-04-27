defmodule SpectreMnemonic.RecallPacket do
  @moduledoc """
  Neighborhood returned by `SpectreMnemonic.recall/2`.
  """

  @type t :: %__MODULE__{
          cue: SpectreMnemonic.Cue.t() | term(),
          active_status: [map()],
          moments: [SpectreMnemonic.Moment.t()],
          episodes: [SpectreMnemonic.Episode.t()],
          knowledge: [SpectreMnemonic.Knowledge.t()],
          artifacts: [SpectreMnemonic.Artifact.t()],
          associations: [SpectreMnemonic.Association.t()],
          action_recipes: [SpectreMnemonic.ActionRecipe.t()],
          confidence: float()
        }

  defstruct [
    :cue,
    active_status: [],
    moments: [],
    episodes: [],
    knowledge: [],
    artifacts: [],
    associations: [],
    action_recipes: [],
    confidence: 0.0
  ]
end
