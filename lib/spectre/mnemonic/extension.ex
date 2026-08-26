if Code.ensure_loaded?(Spectre.Extension) do
  defmodule Spectre.Mnemonic.Extension do
    @moduledoc false

    @behaviour Spectre.Extension

    @impl true
    def id, do: :mnemonic

    @impl true
    def api_version, do: 1

    @impl true
    def compile(_owner, opts) do
      case Keyword.fetch(opts, :stack_config) do
        {:ok, config} when is_map(config) -> {:ok, config}
        {:ok, invalid} -> {:error, {:invalid_mnemonic_stack_config, invalid}}
        :error -> {:ok, %{options: opts, store: nil, isolate_by: []}}
      end
    end

    @impl true
    def agent_config(config) when is_map(config) do
      [mnemonic: config, memory: Spectre.Mnemonic.Memory]
    end
  end
end
