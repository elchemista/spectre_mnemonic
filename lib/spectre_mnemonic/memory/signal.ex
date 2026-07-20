defmodule SpectreMnemonic.Memory.Signal do
  @moduledoc """
  Raw input accepted by `SpectreMnemonic.signal/2`.

  A signal is the unprocessed event before the focus process turns it into an
  active memory moment.
  """

  @type t :: %__MODULE__{
          id: binary(),
          namespace: binary(),
          scope: term(),
          input: term(),
          kind: atom(),
          stream: term(),
          task_id: term(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  defstruct [:id, :namespace, :scope, :input, :kind, :stream, :task_id, :metadata, :inserted_at]
end
