defmodule SpectreMnemonic.Persistence.Store.Disk do
  @moduledoc """
  Backward-compatible facade for the default append-only file storage.

  New code should use `SpectreMnemonic.Persistence.Manager` and
  `SpectreMnemonic.Persistence.Store.File` directly.
  """

  alias SpectreMnemonic.Persistence.Store.File

  @doc "No-op compatibility start function for older supervision trees."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts) do
    Task.start_link(fn -> Process.sleep(:infinity) end)
  end

  @doc "Appends a family-tagged record to the default file store."
  @spec append(atom(), term()) :: {:ok, pos_integer()} | {:error, term()}
  def append(family, record) do
    payload = %SpectreMnemonic.Persistence.Store.Record{
      id: "pmem_#{System.unique_integer([:positive, :monotonic])}",
      family: family,
      operation: :put,
      payload: record,
      dedupe_key: "#{family}:put:#{payload_id(record)}",
      inserted_at: DateTime.utc_now(),
      source_event_id: payload_id(record),
      metadata: %{}
    }

    File.put(payload, data_root: data_root())
  end

  @doc "Replays all complete frames from the default file store."
  @spec replay :: {:ok, [tuple()]}
  def replay do
    {:ok, frames} = File.replay(data_root: data_root())
    {:ok, Enum.map(frames, &legacy_frame/1)}
  end

  @doc "Compacts current replayable records into a snapshot file."
  @spec compact :: {:ok, Path.t()} | {:error, term()}
  def compact do
    File.compact(data_root: data_root())
  end

  @doc "Returns the configured data root."
  @spec data_root :: Path.t()
  def data_root do
    File.data_root()
  end

  @spec payload_id(term()) :: binary() | nil
  defp payload_id(%{id: id}) when is_binary(id), do: id
  defp payload_id(%{id: id}) when is_atom(id), do: Atom.to_string(id)
  defp payload_id(_record), do: nil

  @spec legacy_frame(term()) :: term()
  defp legacy_frame({seq, timestamp, %SpectreMnemonic.Persistence.Store.Record{} = record}) do
    {seq, timestamp, {record.family, record.payload}}
  end

  defp legacy_frame(frame), do: frame
end
