defmodule SpectreMnemonic.Store.Disk do
  @moduledoc """
  Backward-compatible facade for the default append-only file storage.

  New code should use `SpectreMnemonic.PersistentMemory` and
  `SpectreMnemonic.Store.FileStorage` directly.
  """

  alias SpectreMnemonic.Store.FileStorage

  @doc "No-op compatibility start function for older supervision trees."
  def start_link(_opts) do
    Task.start_link(fn -> Process.sleep(:infinity) end)
  end

  @doc "Appends a family-tagged record to the default file store."
  def append(family, record) do
    payload = %SpectreMnemonic.Store.Record{
      id: "pmem_#{System.unique_integer([:positive, :monotonic])}",
      family: family,
      operation: :put,
      payload: record,
      dedupe_key: "#{family}:put:#{payload_id(record)}",
      inserted_at: DateTime.utc_now(),
      source_event_id: payload_id(record),
      metadata: %{}
    }

    FileStorage.put(payload, data_root: data_root())
  end

  @doc "Replays all complete frames from the default file store."
  def replay do
    {:ok, frames} = FileStorage.replay(data_root: data_root())
    {:ok, Enum.map(frames, &legacy_frame/1)}
  end

  @doc "Compacts current replayable records into a snapshot file."
  def compact do
    FileStorage.compact(data_root: data_root())
  end

  @doc "Returns the configured data root."
  def data_root do
    FileStorage.data_root()
  end

  defp payload_id(%{id: id}) when is_binary(id), do: id
  defp payload_id(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp payload_id(_record), do: nil

  defp legacy_frame({seq, timestamp, %SpectreMnemonic.Store.Record{} = record}) do
    {seq, timestamp, {record.family, record.payload}}
  end

  defp legacy_frame(frame), do: frame
end
