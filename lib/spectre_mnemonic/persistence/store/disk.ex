defmodule SpectreMnemonic.Persistence.Store.Disk do
  @moduledoc """
  Backward-compatible facade for the default append-only file storage.

  New code should use `SpectreMnemonic.Persistence.Manager` and
  `SpectreMnemonic.Persistence.Store.File` directly.
  """

  alias SpectreMnemonic.Persistence.Manager
  alias SpectreMnemonic.Persistence.Store.File

  @doc "No-op compatibility start function for older supervision trees."
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts) do
    Task.start_link(fn -> Process.sleep(:infinity) end)
  end

  @doc "Appends a family-tagged record to the default file store."
  @spec append(atom(), term()) :: {:ok, term()} | {:error, term()}
  def append(family, record) do
    # Compatibility layer for older callers. It is not the shiny path, but
    # breaking old supervision trees for elegance would be peak nonsense.
    Manager.append(family, record)
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
    case Manager.compact(mode: :physical) do
      {:ok, [{_store, {:ok, path}} | _]} -> {:ok, path}
      {:ok, results} -> {:error, {:unexpected_compaction_result, results}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the configured data root."
  @spec data_root :: Path.t()
  def data_root do
    File.data_root()
  end

  @spec legacy_frame(term()) :: term()
  defp legacy_frame({seq, timestamp, %SpectreMnemonic.Persistence.Store.Record{} = record}) do
    {seq, timestamp, {record.family, record.payload}}
  end

  defp legacy_frame(frame), do: frame
end
