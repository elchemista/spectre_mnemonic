defmodule SpectreMnemonic.Persistence.Store.Conformance do
  @moduledoc """
  Structural conformance checks shared by every persistence adapter.

  Behavioural suites can build on this audit, but an adapter cannot be marked
  conformant unless its declared guarantees have matching callbacks. Placeholder
  adapters deliberately fail the audit.
  """

  alias SpectreMnemonic.Persistence.Store.Adapter
  alias SpectreMnemonic.Persistence.Store.Contract

  @type report :: %{
          adapter: module(),
          contract: Contract.t(),
          checks: %{atom() => :ok}
        }

  @doc "Audits one adapter against its advertised contract."
  @spec audit(module(), keyword()) :: {:ok, report()} | {:error, term()}
  def audit(adapter, opts \\ []) do
    with {:ok, contract} <- Adapter.describe(adapter, opts),
         :ok <- reject_placeholder(contract),
         :ok <- require_conformance_claim(contract),
         {:ok, checks} <- callback_checks(contract) do
      {:ok, %{adapter: adapter, contract: contract, checks: checks}}
    end
  end

  @spec reject_placeholder(Contract.t()) :: :ok | {:error, term()}
  defp reject_placeholder(%Contract{placeholder?: true, adapter: adapter}),
    do: {:error, {:adapter_placeholder, adapter}}

  defp reject_placeholder(_contract), do: :ok

  @spec require_conformance_claim(Contract.t()) :: :ok | {:error, term()}
  defp require_conformance_claim(%Contract{conformant?: true}), do: :ok

  defp require_conformance_claim(%Contract{adapter: adapter}),
    do: {:error, {:adapter_not_conformant, adapter}}

  @spec callback_checks(Contract.t()) :: {:ok, %{atom() => :ok}} | {:error, term()}
  defp callback_checks(contract) do
    requirements =
      []
      |> require_if(contract.replay_fold, :replay_fold, 3)
      |> require_if(contract.health_check, :health, 1)
      |> require_if(contract.retry_classification, :classify_retry, 1)
      |> require_if(contract.cursor or contract.pagination, :replay_page, 2)
      |> require_if(contract.batch_commit == :native, :put_batch, 2)
      |> require_if(contract.erase_semantics != :none, :erase_partition, 4)
      |> require_if(contract.erase_semantics != :none, :verify_erased, 4)

    missing =
      Enum.reject(requirements, fn {function, arity} ->
        function_exported?(contract.adapter, function, arity)
      end)

    case missing do
      [] -> {:ok, Map.new(requirements, fn {function, _arity} -> {function, :ok} end)}
      callbacks -> {:error, {:adapter_contract_callbacks_missing, contract.adapter, callbacks}}
    end
  end

  @spec require_if([{atom(), arity()}], boolean(), atom(), arity()) :: [{atom(), arity()}]
  defp require_if(requirements, true, function, arity),
    do: [{function, arity} | requirements]

  defp require_if(requirements, false, _function, _arity), do: requirements
end
