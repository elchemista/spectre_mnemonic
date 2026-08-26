defmodule SpectreMnemonic.Durable.Postings do
  @moduledoc false

  @default_candidate_limit 1_000
  @default_brute_force_threshold 250

  @spec update_doc_freq(:ets.tid(), [binary()], 1 | -1) :: :ok
  def update_doc_freq(table, terms, delta) do
    terms
    |> MapSet.new()
    |> Enum.each(fn term ->
      current = lookup_count(table, term)
      next = current + delta

      if next > 0,
        do: :ets.insert(table, {term, next}),
        else: :ets.delete(table, term)
    end)

    :ok
  end

  @spec update(:ets.tid(), tuple(), [term()], term(), :add | :delete) :: :ok
  def update(table, partition, values, doc_key, operation) do
    values
    |> MapSet.new()
    |> Enum.each(fn value ->
      object = {{partition, value}, doc_key}

      case operation do
        :add -> :ets.insert(table, object)
        :delete -> :ets.delete_object(table, object)
      end
    end)

    :ok
  end

  @spec put_recent(:ets.tid(), tuple(), term(), pos_integer()) :: :ok
  def put_recent(table, partition, key, limit) do
    keys =
      table
      |> lookup_value(partition, [])
      |> List.delete(key)
      |> then(&[key | &1])
      |> Enum.take(limit)

    :ets.insert(table, {partition, keys})
    :ok
  end

  @spec delete_recent(:ets.tid(), tuple(), term()) :: :ok
  def delete_recent(table, partition, key) do
    case table |> lookup_value(partition, []) |> List.delete(key) do
      [] -> :ets.delete(table, partition)
      keys -> :ets.insert(table, {partition, keys})
    end

    :ok
  end

  @spec increment_count(:ets.tid(), tuple()) :: :ok
  def increment_count(table, partition) do
    :ets.update_counter(table, partition, {2, 1}, {partition, 0})
    :ok
  end

  @spec decrement_count(:ets.tid(), tuple()) :: :ok
  def decrement_count(table, partition) do
    case lookup_count(table, partition) - 1 do
      count when count > 0 -> :ets.insert(table, {partition, count})
      _empty -> :ets.delete(table, partition)
    end

    :ok
  end

  @spec partition_count(map(), tuple()) :: non_neg_integer()
  def partition_count(%{partition_counts: table}, partition), do: lookup_count(table, partition)

  @spec recent(map(), tuple()) :: [term()]
  def recent(%{recent: table}, partition), do: lookup_value(table, partition, [])

  @spec doc_frequencies(map(), [binary()]) :: %{optional(binary()) => non_neg_integer()}
  def doc_frequencies(%{doc_freq: table}, terms) do
    terms
    |> Enum.uniq()
    |> Map.new(fn term -> {term, lookup_count(table, term)} end)
  end

  @spec candidate_keys(map(), tuple(), [binary()], [binary()], pos_integer()) ::
          {[term()], :candidate_first, map()}
  def candidate_keys(tables, partition, query_terms, query_entities, limit) do
    initial = {[], MapSet.new(), %{lexical: 0, entity: 0, recent: 0}}

    lexical =
      Enum.flat_map(Enum.uniq(query_terms), fn term ->
        lookup_postings(tables.postings, {partition, term})
      end)

    entity =
      Enum.flat_map(Enum.uniq(query_entities), fn value ->
        lookup_postings(tables.entity_postings, {partition, value})
      end)

    {ids, seen, sources} = add_candidate_keys(initial, lexical, limit, :lexical)
    {ids, seen, sources} = add_candidate_keys({ids, seen, sources}, entity, limit, :entity)

    {ids, _seen, sources} =
      add_candidate_keys(
        {ids, seen, sources},
        recent(tables, partition),
        limit,
        :recent
      )

    {Enum.reverse(ids), :candidate_first, sources}
  end

  @spec candidate_limit(keyword()) :: pos_integer()
  def candidate_limit(opts) do
    requested = Keyword.get(opts, :max_candidates, @default_candidate_limit)

    if is_integer(requested) and requested > 0,
      do: min(requested, @default_candidate_limit),
      else: @default_candidate_limit
  end

  @spec brute_force_threshold(keyword()) :: non_neg_integer()
  def brute_force_threshold(opts) do
    case Keyword.get(opts, :brute_force_threshold, @default_brute_force_threshold) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> @default_brute_force_threshold
    end
  end

  defp lookup_postings(table, key) do
    Enum.map(:ets.lookup(table, key), fn {^key, doc_key} -> doc_key end)
  end

  defp lookup_count(table, key), do: lookup_value(table, key, 0)

  defp lookup_value(table, key, default) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp add_candidate_keys({ids, seen, sources}, candidates, limit, source) do
    {ids, seen, added} =
      Enum.reduce_while(candidates, {ids, seen, 0}, fn key, {acc, set, count} ->
        cond do
          MapSet.size(set) >= limit -> {:halt, {acc, set, count}}
          MapSet.member?(set, key) -> {:cont, {acc, set, count}}
          true -> {:cont, {[key | acc], MapSet.put(set, key), count + 1}}
        end
      end)

    {ids, seen, Map.update!(sources, source, &(&1 + added))}
  end
end
