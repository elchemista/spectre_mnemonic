defmodule SpectreMnemonic.Migration.Assigner do
  @moduledoc """
  Host callback used by the repartition Mix task.

  `source_options/0` and `destination_options/0` return ordinary Mnemonic
  operation options, including Engine and source/destination scope. `assign/1`
  decides the destination scope for each visible durable record.
  """

  alias SpectreMnemonic.Persistence.Store.Record

  @callback source_options() :: keyword()
  @callback destination_options() :: keyword()
  @callback assign(Record.t()) :: term() | :skip | {:ok, term()} | {:error, term()}
end
