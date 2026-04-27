defmodule SpectreMnemonic.Episode do
  @moduledoc """
  Consolidated sequence of related moments.
  """

  @type t :: %__MODULE__{
          id: binary(),
          title: binary(),
          moment_ids: [binary()],
          summary: term(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :title, moment_ids: [], summary: nil, metadata: %{}, inserted_at: nil]
end
