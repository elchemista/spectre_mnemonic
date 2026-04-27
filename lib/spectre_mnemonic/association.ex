defmodule SpectreMnemonic.Association do
  @moduledoc """
  Typed relationship between two memory records.
  """

  @type t :: %__MODULE__{
          id: binary(),
          source_id: binary(),
          relation: atom(),
          target_id: binary(),
          weight: number(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :source_id, :relation, :target_id, weight: 1.0, metadata: %{}, inserted_at: nil]
end
