defmodule SpectreMnemonic.SearchResult do
  @moduledoc """
  Canonical result returned by active and durable search paths.

  Adapter-specific scoring details are preserved in `metadata`; callers can
  otherwise consume one stable result shape regardless of storage backend.
  """

  @type t :: %__MODULE__{
          source: :active | :persistent | atom(),
          namespace: binary() | nil,
          scope: term(),
          store: term(),
          family: atom() | nil,
          id: binary() | nil,
          record_id: binary() | nil,
          rank: pos_integer() | nil,
          score: number(),
          state: atom() | nil,
          record: term(),
          event: term(),
          text: binary() | nil,
          type: atom() | nil,
          provenance: map(),
          inserted_at: DateTime.t() | nil,
          scores: map(),
          metadata: map()
        }

  defstruct [
    :source,
    :namespace,
    :scope,
    :store,
    :family,
    :id,
    :record_id,
    :rank,
    :state,
    :record,
    :event,
    :text,
    :type,
    :inserted_at,
    score: 0.0,
    provenance: %{},
    scores: %{},
    metadata: %{}
  ]

  @known_keys MapSet.new(Map.keys(%__MODULE__{}) -- [:__struct__])

  @doc "Normalizes a map or arbitrary adapter value into one result shape."
  @spec new(term(), keyword()) :: t()
  def new(result, defaults \\ [])

  def new(%__MODULE__{} = result, defaults) do
    Enum.reduce(defaults, result, fn {key, value}, result ->
      if Map.get(result, key) in [nil, ""], do: Map.put(result, key, value), else: result
    end)
  end

  def new(result, defaults) when is_map(result) do
    result = if is_struct(result), do: Map.from_struct(result), else: result
    defaults = Map.new(defaults)
    values = Map.merge(defaults, result)

    struct!(__MODULE__, %{
      source: Map.get(values, :source),
      namespace: Map.get(values, :namespace),
      scope: Map.get(values, :scope),
      store: Map.get(values, :store),
      family: Map.get(values, :family),
      id: Map.get(values, :id),
      record_id: Map.get(values, :record_id),
      rank: Map.get(values, :rank),
      score: Map.get(values, :score, 0.0) || 0.0,
      state: Map.get(values, :state),
      record: Map.get(values, :record, result),
      event: Map.get(values, :event),
      text: Map.get(values, :text),
      type: Map.get(values, :type),
      provenance: Map.get(values, :provenance, %{}) || %{},
      inserted_at: Map.get(values, :inserted_at),
      scores: Map.get(values, :scores, %{}) || %{},
      metadata:
        values
        |> Map.drop(MapSet.to_list(@known_keys))
        |> Map.merge(Map.get(values, :metadata, %{}) || %{})
    })
  end

  def new(result, defaults) do
    defaults
    |> Map.new()
    |> Map.put(:record, result)
    |> new([])
  end

  @doc "Returns a deduplication key that keeps source families distinct."
  @spec key(t()) :: term()
  def key(%__MODULE__{} = result),
    do: {result.source, result.family, result.id || result.record_id}
end
