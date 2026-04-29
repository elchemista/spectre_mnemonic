defmodule SpectreMnemonic.Knowledge.Consolidator.Adapter do
  @moduledoc """
  Optional behaviour for applications that want custom durable-memory promotion.

  Adapters receive a `%SpectreMnemonic.Knowledge.Consolidation{}` containing
  active moments, graph associations, graph windows, default durable outputs,
  the current time, and the original consolidation options. They may update and
  return the same struct.

  Legacy map and list returns are still accepted by the consolidator and
  normalized into a consolidation struct.
  """

  @callback consolidate(
              consolidation :: SpectreMnemonic.Knowledge.Consolidation.t(),
              opts :: keyword()
            ) ::
              {:ok, SpectreMnemonic.Knowledge.Consolidation.t() | map() | list()}
              | {:error, term()}
end
