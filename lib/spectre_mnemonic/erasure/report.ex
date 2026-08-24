defmodule SpectreMnemonic.Erasure.Report do
  @moduledoc "Typed result returned by partition erasure."

  defstruct families: %{},
            hot: %{},
            knowledge_events: 0,
            compaction: :pending,
            marker_id: nil,
            crypto_shred: :unsupported,
            already_erased?: false

  @type t :: %__MODULE__{
          families: %{optional(atom()) => non_neg_integer()},
          hot: map(),
          knowledge_events: non_neg_integer(),
          compaction: :pending | :erased | {:error, term()},
          marker_id: binary(),
          crypto_shred: term(),
          already_erased?: boolean()
        }
end
