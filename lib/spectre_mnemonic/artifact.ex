defmodule SpectreMnemonic.Artifact do
  @moduledoc """
  File, path, binary, or external object remembered by reference.
  """

  @type t :: %__MODULE__{
          id: binary(),
          source: term(),
          content_type: binary() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :source, :content_type, metadata: %{}, inserted_at: nil]
end
