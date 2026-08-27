defmodule SpectreMnemonic.Active.ETSOwner do
  @moduledoc """
  Compatibility facade for the Engine-owned hot store.

  Since 0.2.0 every Engine owns unnamed tables. This module remains only for
  callers that used `member?/2`; it no longer owns runtime state or starts a
  globally registered process.
  """

  alias SpectreMnemonic.Active.ETS

  @doc "Returns true when a key exists in the current Engine hot table."
  @spec member?(atom(), term()) :: boolean()
  def member?(table, key) do
    ETS.member(table, key)
  rescue
    ArgumentError -> false
  end
end
