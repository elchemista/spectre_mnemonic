defmodule SpectreMnemonic.Reflection.Adapter do
  @moduledoc """
  Optional adapter for turning a reflection evidence packet into a response.
  """

  @callback reflect(SpectreMnemonic.Reflection.Packet.t(), keyword()) ::
              {:ok, term()} | {:error, term()} | term()
end
