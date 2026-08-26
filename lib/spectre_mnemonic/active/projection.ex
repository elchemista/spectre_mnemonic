defmodule SpectreMnemonic.Active.Projection do
  @moduledoc false

  alias SpectreMnemonic.Active.ETS
  alias SpectreMnemonic.Engine.Projection, as: CandidateProjection
  alias SpectreMnemonic.Memory.Scope

  @doc false
  @spec put_moment(map(), keyword()) :: true
  def put_moment(moment, opts \\ []) do
    partition = Scope.partition(moment)
    ETS.insert(:mnemonic_moments, {moment.id, moment})
    ETS.insert(:mnemonic_moments_by_stream, {{partition, moment.stream}, moment.id})

    if moment.task_id do
      ETS.insert(:mnemonic_moments_by_task, {{partition, moment.task_id}, moment.id})
    end

    ETS.insert(:mnemonic_moments_by_scope, {partition, moment.id})

    if is_binary(moment.signal_id) and moment.signal_id != "" do
      ETS.insert(:mnemonic_moments_by_signal, {moment.signal_id, moment.id})
    end

    ETS.insert(:mnemonic_atlas_dirty, {partition, moment.id})
    CandidateProjection.upsert(moment, opts)
    true
  end

  @doc false
  @spec put_association(map()) :: true
  def put_association(association) do
    partition = Scope.partition(association)
    ETS.insert(:mnemonic_associations, {association.id, association})
    ETS.insert(:mnemonic_associations_by_scope, {partition, association.id})

    ETS.insert(
      :mnemonic_associations_by_memory,
      {{partition, association.source_id}, association.id}
    )

    ETS.insert(
      :mnemonic_associations_by_memory,
      {{partition, association.target_id}, association.id}
    )

    if association.relation not in [:attached_action, :member_of, :same_as] do
      ETS.insert(:mnemonic_atlas_dirty, {partition, association.source_id})
      ETS.insert(:mnemonic_atlas_dirty, {partition, association.target_id})
    end
  end

  @doc false
  @spec delete_association(map()) :: true
  def delete_association(association) do
    partition = Scope.partition(association)
    ETS.delete(:mnemonic_associations, association.id)
    ETS.delete_object(:mnemonic_associations_by_scope, {partition, association.id})

    ETS.delete_object(
      :mnemonic_associations_by_memory,
      {{partition, association.source_id}, association.id}
    )

    ETS.delete_object(
      :mnemonic_associations_by_memory,
      {{partition, association.target_id}, association.id}
    )
  end

  @doc false
  @spec delete_moment_indexes(map()) :: :ok
  def delete_moment_indexes(moment) do
    partition = Scope.partition(moment)
    ETS.delete_object(:mnemonic_moments_by_stream, {{partition, moment.stream}, moment.id})

    if moment.task_id do
      ETS.delete_object(:mnemonic_moments_by_task, {{partition, moment.task_id}, moment.id})
    end

    ETS.delete_object(:mnemonic_moments_by_scope, {partition, moment.id})

    if is_binary(moment.signal_id) and moment.signal_id != "" do
      ETS.delete(:mnemonic_moments_by_signal, moment.signal_id)
    end

    :ok
  end

  @doc false
  @spec delete_candidate(map()) :: :ok
  def delete_candidate(moment), do: CandidateProjection.delete(moment)
end
