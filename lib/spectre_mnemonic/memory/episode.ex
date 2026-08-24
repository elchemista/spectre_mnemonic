defmodule SpectreMnemonic.Memory.Episode do
  @moduledoc """
  Consolidated sequence of related moments.
  """

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          scope: term(),
          title: binary(),
          moment_ids: [binary()],
          summary: term(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :namespace,
    :scope,
    :title,
    moment_ids: [],
    summary: nil,
    metadata: %{},
    inserted_at: nil
  ]
end
