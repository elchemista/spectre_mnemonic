defmodule Spectre.Mnemonic.ServerTool.Projection do
  @moduledoc false

  # Explicit public fields: new record types and newly-added fields are never
  # silently persisted into an agent conversation. Generic metadata, raw input,
  # storage configuration, embeddings and runtime handles remain private.
  @fields %{
    SpectreMnemonic.Recall.Packet =>
      ~w(cue query_context search_results active_status moments observations mental_models episodes knowledge artifacts associations action_recipes confidence usage)a,
    SpectreMnemonic.Intake.Packet =>
      ~w(root events moments chunks summaries categories associations warnings errors persistence)a,
    SpectreMnemonic.QueryContext => ~w(text namespace scope scopes keywords entities)a,
    SpectreMnemonic.Recall.Cue => ~w(text keywords entities)a,
    SpectreMnemonic.SearchResult =>
      ~w(source namespace scope family id record_id rank state record type inserted_at score scores)a,
    SpectreMnemonic.Memory.Moment =>
      ~w(id namespace signal_id stream task_id scope kind text inserted_at occurred_at observed_at last_verified_at valid_from valid_until keywords entities attention)a,
    SpectreMnemonic.Memory.Signal => ~w(id namespace scope kind stream task_id inserted_at)a,
    SpectreMnemonic.Memory.Observation =>
      ~w(id namespace statement scope occurred_at observed_at last_verified_at valid_from valid_until inserted_at tags source_ids evidence proof_count contradiction_count confidence trend state keywords entities)a,
    SpectreMnemonic.Memory.MentalModel =>
      ~w(id namespace title query answer scope occurred_at observed_at last_verified_at valid_from valid_until inserted_at source_ids citations state keywords entities)a,
    SpectreMnemonic.Memory.Episode =>
      ~w(id namespace scope title moment_ids summary inserted_at)a,
    SpectreMnemonic.Knowledge.Record =>
      ~w(id namespace scope source_id text summary skills latest_ingestions facts procedures usage inserted_at)a,
    SpectreMnemonic.Memory.Skill => ~w(id name steps inserted_at)a,
    SpectreMnemonic.Memory.Artifact => ~w(id namespace scope content_type inserted_at)a,
    SpectreMnemonic.Memory.Association =>
      ~w(id namespace scope source_id relation target_id weight inserted_at)a,
    SpectreMnemonic.Memory.ActionRecipe =>
      ~w(id namespace scope memory_id language text intent status inserted_at)a,
    SpectreMnemonic.Persistence.Store.Record =>
      ~w(id namespace scope family operation operation_id commit_id batch_id revision payload inserted_at source_event_id schema_version)a,
    SpectreMnemonic.Persistence.WriteReceipt =>
      ~w(schema_version operation_id commit_id batch_id status primary repair_required? idempotent?)a
  }

  def to_data(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def to_data(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def to_data(%SpectreMnemonic.Memory.Secret{} = value) do
    value
    |> Map.take([:id, :namespace, :secret_id, :label, :scope])
    |> Map.merge(%{locked?: true, revealed?: false})
    |> to_data()
  end

  def to_data(%module{} = value) do
    case Map.fetch(@fields, module) do
      {:ok, fields} -> value |> Map.take(fields) |> to_data()
      :error -> raise ArgumentError, "unsupported memory record"
    end
  end

  def to_data(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_data(key), to_data(item)} end)

  def to_data(value) when is_list(value), do: Enum.map(value, &to_data/1)

  def to_data(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&to_data/1) |> List.to_tuple()

  def to_data(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  def to_data(_value), do: raise(ArgumentError, "nonportable memory value")
end
