defmodule SpectreMnemonic.Reflection.Adapter do
  @moduledoc """
  Legacy compatibility behaviour for external Spectre response generators.

  The memory engine no longer invokes this callback. It returns structured
  evidence; a calling Spectre layer owns response generation and may implement
  this behaviour while migrating older code.
  """

  @callback reflect(SpectreMnemonic.Reflection.Packet.t(), keyword()) ::
              {:ok, term()} | {:error, term()} | term()
end
