defmodule SpectreMnemonic.Persistence.Store.Contract do
  @moduledoc """
  Machine-readable persistence adapter contract.

  The contract separates capabilities implemented by the adapter itself from
  guarantees supplied by the Mnemonic persistence pipeline. This keeps an
  append-only file store, a transactional database, and an archive adapter
  honest about the semantics callers can rely on.
  """

  @enforce_keys [:adapter]
  defstruct adapter: nil,
            schema_versions: [2],
            idempotency_key: :none,
            operation_id: :optional,
            batch_commit: :none,
            commit_revision: :none,
            cursor: false,
            pagination: false,
            replay_fold: false,
            conflict_detection: :none,
            erase_semantics: :none,
            health_check: false,
            retry_classification: false,
            transactional: :none,
            max_batch_size: 1,
            placeholder?: false,
            conformant?: false

  @type idempotency_key :: :operation_id | :dedupe_key | :none
  @type support :: :required | :optional | :unsupported
  @type batch_commit :: :native | :framed_markers | :none
  @type commit_revision :: :native | :record | :none
  @type conflict_detection :: :native | :digest | :none
  @type erase_semantics :: :physical | :tombstone | :crypto_shred | :none
  @type transactional :: :full | :batch | :append_frame | :none

  @type t :: %__MODULE__{
          adapter: module(),
          schema_versions: [pos_integer()],
          idempotency_key: idempotency_key(),
          operation_id: support(),
          batch_commit: batch_commit(),
          commit_revision: commit_revision(),
          cursor: boolean(),
          pagination: boolean(),
          replay_fold: boolean(),
          conflict_detection: conflict_detection(),
          erase_semantics: erase_semantics(),
          health_check: boolean(),
          retry_classification: boolean(),
          transactional: transactional(),
          max_batch_size: pos_integer(),
          placeholder?: boolean(),
          conformant?: boolean()
        }

  @doc "Validates a contract before it is exposed to diagnostics or conformance tests."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = contract) do
    contract
    |> validation_results()
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  def validate(_other), do: {:error, {:invalid_store_contract, :shape}}

  @spec validation_results(t()) :: [:ok | {:error, term()}]
  defp validation_results(contract) do
    [
      validate_predicate(is_atom(contract.adapter), :adapter),
      validate_predicate(valid_schema_versions?(contract.schema_versions), :schema_versions),
      validate_member(
        contract.idempotency_key,
        [:operation_id, :dedupe_key, :none],
        :idempotency_key
      ),
      validate_member(contract.operation_id, [:required, :optional, :unsupported], :operation_id),
      validate_member(contract.batch_commit, [:native, :framed_markers, :none], :batch_commit),
      validate_member(contract.commit_revision, [:native, :record, :none], :commit_revision),
      validate_member(
        contract.conflict_detection,
        [:native, :digest, :none],
        :conflict_detection
      ),
      validate_member(
        contract.erase_semantics,
        [:physical, :tombstone, :crypto_shred, :none],
        :erase_semantics
      ),
      validate_member(
        contract.transactional,
        [:full, :batch, :append_frame, :none],
        :transactional
      ),
      validate_predicate(
        is_integer(contract.max_batch_size) and contract.max_batch_size > 0,
        :max_batch_size
      ),
      validate_predicate(boolean_fields?(contract), :boolean_field),
      validate_predicate(
        not (contract.placeholder? and contract.conformant?),
        :placeholder_conformant
      )
    ]
  end

  @spec valid_schema_versions?(term()) :: boolean()
  defp valid_schema_versions?(versions) when is_list(versions) and versions != [],
    do: Enum.all?(versions, &(is_integer(&1) and &1 > 0))

  defp valid_schema_versions?(_versions), do: false

  @spec validate_member(term(), [term()], atom()) :: :ok | {:error, term()}
  defp validate_member(value, allowed, field),
    do: validate_predicate(value in allowed, field)

  @spec validate_predicate(boolean(), atom()) :: :ok | {:error, term()}
  defp validate_predicate(true, _field), do: :ok
  defp validate_predicate(false, field), do: {:error, {:invalid_store_contract, field}}

  @spec boolean_fields?(t()) :: boolean()
  defp boolean_fields?(contract) do
    Enum.all?(
      [
        contract.cursor,
        contract.pagination,
        contract.replay_fold,
        contract.health_check,
        contract.retry_classification,
        contract.placeholder?,
        contract.conformant?
      ],
      &is_boolean/1
    )
  end
end
