defmodule SpectreMnemonic.Intake.Memory do
  @moduledoc """
  Draft memory that moves through the `remember/2` plug pipeline.

  This struct is not persisted. Plugs use it to classify, enrich, reroute, or
  halt intake before the draft becomes a stored moment or encrypted secret.
  """

  @typedoc """
  Draft carrier for remember intake.

  Input/context fields (`input`, `text`, `kind`, `stream`, `task_id`,
  `metadata`, `tags`, `title`, and `recent_moments`) are filled before plugs
  run. Plugs may set `secret?`, `label`, `assigns`, warnings/errors, or a final
  `result`.
  """
  @type t :: %__MODULE__{
          input: term(),
          text: binary(),
          kind: atom(),
          stream: term(),
          task_id: term(),
          metadata: map(),
          tags: [term()],
          title: binary(),
          secret?: boolean(),
          label: binary() | nil,
          assigns: map(),
          warnings: [term()],
          errors: [term()],
          recent_moments: [SpectreMnemonic.Memory.Moment.t() | SpectreMnemonic.Memory.Secret.t()],
          result: term(),
          halted?: boolean()
        }

  defstruct [
    :input,
    :text,
    :kind,
    :stream,
    :task_id,
    :title,
    :label,
    :result,
    metadata: %{},
    tags: [],
    secret?: false,
    assigns: %{},
    warnings: [],
    errors: [],
    recent_moments: [],
    halted?: false
  ]
end
