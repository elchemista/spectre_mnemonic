defmodule SpectreMnemonic.Knowledge.Consolidation do
  @moduledoc """
  Single carrier for durable memory consolidation.

  The library fills the active-memory context, graph windows, and default durable
  outputs before handing this struct to a consolidation adapter. Adapters can
  update the same struct and return it for persistence.
  """

  alias SpectreMnemonic.Knowledge.Record
  alias SpectreMnemonic.Memory.{Association, Moment, Secret}

  @typedoc "Plain map describing one graph-connected chunk of candidate memories."
  @type window :: %{
          id: binary(),
          moment_ids: [binary()],
          association_ids: [binary()],
          stream: term(),
          task_ids: [term()],
          time_range: %{from: DateTime.t() | nil, to: DateTime.t() | nil},
          keywords: [binary()],
          metadata: map()
        }

  @typedoc "Extra durable family write requested by a consolidation adapter."
  @type record_entry :: {atom(), term()}

  @typedoc "Durable deletion marker requested by a consolidation adapter."
  @type tombstone ::
          %{required(:family) => atom(), required(:id) => binary(), optional(atom()) => term()}
          | {atom(), binary()}

  @typedoc """
  Single carrier passed through durable consolidation.

  The library fills `moments`, `associations`, `windows`, `now`, `opts`, and
  default durable output fields before invoking adapters. Adapters update this
  same struct and return it.
  """
  @type t :: %__MODULE__{
          moments: [Moment.t() | Secret.t()],
          associations: [Association.t()],
          windows: [window()],
          now: DateTime.t() | nil,
          opts: keyword(),
          knowledge: [Record.t()],
          summaries: [Moment.t()],
          categories: [Moment.t()],
          embeddings: [map()],
          records: [record_entry()],
          tombstones: [tombstone()],
          strategy: atom(),
          metadata: map(),
          warnings: [term()],
          errors: [term()]
        }

  defstruct [
    :now,
    moments: [],
    associations: [],
    windows: [],
    opts: [],
    knowledge: [],
    summaries: [],
    categories: [],
    embeddings: [],
    records: [],
    tombstones: [],
    strategy: :default,
    metadata: %{},
    warnings: [],
    errors: []
  ]
end
