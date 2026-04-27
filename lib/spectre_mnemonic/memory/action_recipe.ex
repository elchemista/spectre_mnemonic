defmodule SpectreMnemonic.Memory.ActionRecipe do
  @moduledoc """
  English-like Action Language recipe attached to a memory record.

  Recipes describe executable intent, but SpectreMnemonic treats them as data.
  Parsing, safety checks, and execution belong to an external runtime such as
  `spectre_kinetic`.
  """

  @type status :: :stored | :draft | :approved | :disabled | atom()

  @type t :: %__MODULE__{
          id: binary(),
          memory_id: binary(),
          language: atom(),
          text: binary(),
          intent: binary() | nil,
          status: status(),
          metadata: map(),
          inserted_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :memory_id,
    language: :spectre_al,
    text: "",
    intent: nil,
    status: :stored,
    metadata: %{},
    inserted_at: nil
  ]
end
