defmodule SpectreMnemonic.Engine.Ref do
  @moduledoc "Stable, process-free identity of a SpectreMnemonic Engine."

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: binary()}

  @doc "Builds an Engine reference from a stable logical id."
  @spec new(term()) :: t()
  def new(%__MODULE__{} = ref), do: ref

  def new(id) when is_atom(id) and not is_nil(id), do: new(Atom.to_string(id))

  def new(id) when is_binary(id) do
    case String.trim(id) do
      "" -> raise ArgumentError, "Engine Ref id cannot be empty"
      normalized -> %__MODULE__{id: normalized}
    end
  end

  def new(id), do: raise(ArgumentError, "invalid Engine Ref id: #{inspect(id)}")
end
