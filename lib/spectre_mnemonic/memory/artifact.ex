defmodule SpectreMnemonic.Memory.Artifact do
  @moduledoc """
  File, path, binary, or external object remembered by reference.
  """

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          scope: term(),
          source: term(),
          content_type: binary() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :namespace, :scope, :source, :content_type, metadata: %{}, inserted_at: nil]
end
