defmodule SpectreMnemonic.Atlas.LabelAdapter do
  @moduledoc """
  Optional adapter for improving deterministic Atlas cluster labels.

  The adapter receives a bounded, partition-local label input and must return a
  short title. Atlas always falls back to its deterministic entity/keyword
  label when an adapter is absent, invalid, raises, or returns an error.
  """

  @type input :: %{
          required(:default_title) => binary(),
          required(:member_ids) => [binary()],
          required(:members) => [term()]
        }

  @callback label(input(), keyword()) :: {:ok, binary()} | {:error, term()}
end
