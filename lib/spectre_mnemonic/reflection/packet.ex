defmodule SpectreMnemonic.Reflection.Packet do
  @moduledoc """
  Evidence packet returned by `SpectreMnemonic.reflect/2`.
  """

  @type t :: %__MODULE__{
          query: term(),
          mental_models: [SpectreMnemonic.Memory.MentalModel.t()],
          observations: [SpectreMnemonic.Memory.Observation.t()],
          raw_memories: [SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()],
          knowledge: [SpectreMnemonic.Knowledge.Record.t()],
          evidence: [map()],
          citations: [map()],
          directives: term(),
          disposition: term(),
          response: term(),
          confidence: float(),
          usage: map(),
          metadata: map()
        }

  defstruct [
    :query,
    :directives,
    :disposition,
    :response,
    mental_models: [],
    observations: [],
    raw_memories: [],
    knowledge: [],
    evidence: [],
    citations: [],
    confidence: 0.0,
    usage: %{},
    metadata: %{}
  ]
end
