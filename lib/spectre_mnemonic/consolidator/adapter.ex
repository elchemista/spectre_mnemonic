defmodule SpectreMnemonic.Consolidator.Adapter do
  @moduledoc """
  Optional behaviour for applications that want custom durable-memory promotion.

  Adapters receive active moments, graph associations, the current time, and the
  original consolidation options. They return a consolidation plan map.
  """

  @callback consolidate(context :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
