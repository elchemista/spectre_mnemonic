defmodule SpectreMnemonic.Skill do
  @moduledoc """
  Reusable procedure or learned behavior.
  """

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          steps: [term()],
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :name, :steps, metadata: %{}, inserted_at: nil]
end
