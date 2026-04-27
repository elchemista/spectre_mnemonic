defmodule SpectreMnemonic.MemoryPacket do
  @moduledoc """
  Result returned by `SpectreMnemonic.remember/2`.

  A packet is the visible shape of one intake run: the root memory, derived
  chunks, summaries, category nodes, graph edges, and operational notes.
  """

  @type t :: %__MODULE__{
          root: SpectreMnemonic.Moment.t() | nil,
          events: [SpectreMnemonic.Signal.t()],
          moments: [SpectreMnemonic.Moment.t()],
          chunks: [SpectreMnemonic.Moment.t()],
          summaries: [SpectreMnemonic.Moment.t()],
          categories: [SpectreMnemonic.Moment.t()],
          associations: [SpectreMnemonic.Association.t()],
          warnings: [term()],
          errors: [term()],
          persistence: map()
        }

  defstruct [
    :root,
    events: [],
    moments: [],
    chunks: [],
    summaries: [],
    categories: [],
    associations: [],
    warnings: [],
    errors: [],
    persistence: %{mode: :active}
  ]
end
