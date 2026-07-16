defmodule SpectreMnemonic.Reflection.Adapter do
  @moduledoc """
  Legacy compatibility behaviour for external Spectre response generators.

  `SpectreMnemonic.Reflection` no longer invokes this callback. The memory
  library returns structured evidence; a calling Spectre layer owns response
  generation and may implement this behaviour while migrating older code.
  """

  @callback reflect(SpectreMnemonic.Reflection.Packet.t(), keyword()) ::
              {:ok, term()} | {:error, term()} | term()
end
