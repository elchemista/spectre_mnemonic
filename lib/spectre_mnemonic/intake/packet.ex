defmodule SpectreMnemonic.Intake.Packet do
  @moduledoc """
  Result returned by `SpectreMnemonic.remember/2`.

  A packet is the visible shape of one intake run: the root memory, derived
  chunks, summaries, category nodes, graph edges, and operational notes.
  """

  @typedoc "Return packet produced by `SpectreMnemonic.remember/2`."
  @type t :: %__MODULE__{
          root: SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t() | nil,
          events: [SpectreMnemonic.Memory.Signal.t()],
          moments: [SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()],
          chunks: [SpectreMnemonic.Memory.Moment.t()],
          summaries: [SpectreMnemonic.Memory.Moment.t()],
          categories: [SpectreMnemonic.Memory.Moment.t()],
          associations: [SpectreMnemonic.Memory.Association.t()],
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
