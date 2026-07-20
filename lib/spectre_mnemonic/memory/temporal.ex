defmodule SpectreMnemonic.Memory.Temporal do
  @moduledoc false

  @fields [:occurred_at, :observed_at, :last_verified_at, :valid_from, :valid_until]

  @doc "Known temporal fields copied into memories and provenance metadata."
  @spec fields :: [atom()]
  def fields, do: @fields

  @doc "Normalizes supported DateTime option values."
  @spec normalize(term()) :: DateTime.t() | nil
  def normalize(%DateTime{} = value), do: value

  def normalize(%NaiveDateTime{} = value) do
    # Naive times get UTC because this library needs a boring default. If the
    # caller cares about timezone nuance, they should send a DateTime. Per favore.
    DateTime.from_naive!(value, "Etc/UTC")
  end

  def normalize(%Date{} = value) do
    value
    |> NaiveDateTime.new!(~T[00:00:00])
    |> DateTime.from_naive!("Etc/UTC")
  end

  def normalize(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  def normalize(_value), do: nil

  @doc "Returns normalized temporal fields from opts, defaulting observed_at to now."
  @spec from_opts(keyword(), DateTime.t()) :: map()
  def from_opts(opts, now) do
    @fields
    |> Map.new(fn field ->
      default = if field == :observed_at, do: now, else: nil
      value = Keyword.get(opts, field)
      {field, normalize(value || default)}
    end)
  end

  @doc "Merges temporal fields into a metadata map."
  @spec put_metadata(map(), map()) :: map()
  def put_metadata(metadata, temporal) when is_map(metadata) and is_map(temporal) do
    temporal
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.reduce(metadata, fn {key, value}, acc -> Map.put_new(acc, key, value) end)
  end

  @doc "Returns true when a memory-like map satisfies temporal filters."
  @spec match?(map(), keyword()) :: boolean()
  def match?(memory, opts) do
    # Temporal filters keep old context from wandering into every room. Memory
    # without time is still allowed, but range filters are allowed to be picky.
    temporal = temporal_map(memory)

    Enum.all?([
      compare_after(Map.get(temporal, :occurred_at), Keyword.get(opts, :occurred_after)),
      compare_before(Map.get(temporal, :occurred_at), Keyword.get(opts, :occurred_before)),
      compare_after(Map.get(temporal, :observed_at), Keyword.get(opts, :observed_after)),
      compare_before(Map.get(temporal, :observed_at), Keyword.get(opts, :observed_before)),
      valid_at?(temporal, Keyword.get(opts, :valid_at))
    ])
  end

  @doc "Extracts temporal fields from direct fields or metadata/provenance."
  @spec temporal_map(map()) :: map()
  def temporal_map(memory) when is_map(memory) do
    metadata = memory |> map_values(:metadata) |> Enum.filter(&is_map/1)

    provenance =
      metadata
      |> Enum.flat_map(&map_values(&1, :provenance))
      |> Enum.filter(&is_map/1)

    sources = [memory | metadata ++ provenance]

    @fields
    |> Map.new(fn field ->
      value =
        Enum.find_value(sources, fn source ->
          source
          |> map_values(field)
          |> Enum.find_value(&normalize/1)
        end)

      {field, value}
    end)
  end

  def temporal_map(_memory), do: %{}

  @spec map_values(map(), atom()) :: [term()]
  defp map_values(map, key) do
    string_key = Atom.to_string(key)

    []
    |> maybe_prepend(Map.has_key?(map, string_key), Map.get(map, string_key))
    |> maybe_prepend(Map.has_key?(map, key), Map.get(map, key))
  end

  @spec maybe_prepend([term()], boolean(), term()) :: [term()]
  defp maybe_prepend(values, true, value), do: [value | values]
  defp maybe_prepend(values, false, _value), do: values

  @spec compare_after(DateTime.t() | nil, term()) :: boolean()
  defp compare_after(_value, nil), do: true

  defp compare_after(value, cutoff) do
    case normalize(cutoff) do
      nil -> true
      _cutoff when is_nil(value) -> false
      cutoff -> DateTime.compare(value, cutoff) in [:gt, :eq]
    end
  end

  @spec compare_before(DateTime.t() | nil, term()) :: boolean()
  defp compare_before(_value, nil), do: true

  defp compare_before(value, cutoff) do
    case normalize(cutoff) do
      nil -> true
      _cutoff when is_nil(value) -> false
      cutoff -> DateTime.compare(value, cutoff) in [:lt, :eq]
    end
  end

  @spec valid_at?(map(), term()) :: boolean()
  defp valid_at?(_temporal, nil), do: true

  defp valid_at?(temporal, value) do
    case normalize(value) do
      nil ->
        true

      at ->
        valid_from = Map.get(temporal, :valid_from)
        valid_until = Map.get(temporal, :valid_until)

        (is_nil(valid_from) or DateTime.compare(valid_from, at) in [:lt, :eq]) and
          (is_nil(valid_until) or DateTime.compare(valid_until, at) in [:gt, :eq])
    end
  end
end
