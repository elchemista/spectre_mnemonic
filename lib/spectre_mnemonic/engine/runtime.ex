defmodule SpectreMnemonic.Engine.Runtime do
  @moduledoc """
  Ephemeral result of resolving a running Engine.

  A Runtime contains local process ownership and must never be persisted,
  placed in a Spectre Run, or used as durable identity. Persist
  `SpectreMnemonic.Engine.Ref` or `storage_id` instead.
  """

  @enforce_keys [:config, :engine_pid]
  defstruct [:config, :engine_pid, :owner]

  @type t :: %__MODULE__{
          config: SpectreMnemonic.Engine.Config.t(),
          engine_pid: pid(),
          owner: pid() | nil
        }
end
