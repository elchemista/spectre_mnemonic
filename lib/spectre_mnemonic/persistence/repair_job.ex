defmodule SpectreMnemonic.Persistence.RepairJob do
  @moduledoc false

  @enforce_keys [:id, :commit_id, :target_store, :record, :store]
  defstruct id: nil,
            commit_id: nil,
            target_store: nil,
            attempts: 0,
            status: :pending,
            last_error: nil,
            inserted_at: nil,
            updated_at: nil,
            record: nil,
            store: nil

  @type t :: %__MODULE__{
          id: binary(),
          commit_id: binary(),
          target_store: term(),
          attempts: non_neg_integer(),
          status: :pending | :retrying | :completed,
          last_error: term(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          record: SpectreMnemonic.Persistence.Store.Record.t(),
          store: map()
        }
end
