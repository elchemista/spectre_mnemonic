defmodule SpectreMnemonic.Stream do
  @moduledoc """
  Named activity lane, such as `:chat`, `:research`, or a task-specific stream.
  """

  @type t :: %__MODULE__{
          id: binary() | nil,
          name: term(),
          task_id: term(),
          status: atom(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [:id, :name, :task_id, status: :active, metadata: %{}, inserted_at: nil]
end
