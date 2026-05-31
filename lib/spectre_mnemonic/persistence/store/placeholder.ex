defmodule SpectreMnemonic.Persistence.Store.Placeholder do
  @moduledoc false

  defmacro __using__(capabilities) do
    quote bind_quoted: [capabilities: capabilities] do
      @behaviour SpectreMnemonic.Persistence.Store.Adapter
      @capabilities capabilities

      @impl SpectreMnemonic.Persistence.Store.Adapter
      @spec capabilities(keyword()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
      def capabilities(_opts), do: @capabilities

      @impl SpectreMnemonic.Persistence.Store.Adapter
      @spec put(SpectreMnemonic.Persistence.Store.Record.t(), keyword()) :: {:error, term()}
      def put(_record, _opts), do: missing_adapter_implementation()

      @impl SpectreMnemonic.Persistence.Store.Adapter
      @spec get(atom(), binary(), keyword()) :: {:error, term()}
      def get(_family, _id, _opts), do: missing_adapter_implementation()

      @impl SpectreMnemonic.Persistence.Store.Adapter
      @spec search(term(), keyword()) :: {:error, term()}
      def search(_cue, _opts), do: missing_adapter_implementation()

      @impl SpectreMnemonic.Persistence.Store.Adapter
      @spec delete_or_tombstone(atom(), binary(), keyword()) :: {:error, term()}
      def delete_or_tombstone(_family, _id, _opts), do: missing_adapter_implementation()

      @spec missing_adapter_implementation :: {:error, term()}
      defp missing_adapter_implementation,
        do: {:error, {:missing_adapter_implementation, __MODULE__}}
    end
  end
end
