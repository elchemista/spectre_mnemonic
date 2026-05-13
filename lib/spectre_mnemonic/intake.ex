defmodule SpectreMnemonic.Intake do
  @moduledoc """
  Unified intake pipeline behind `SpectreMnemonic.remember/2`.

  Intake accepts already-parsed information, keeps JSON-looking strings as text,
  creates active memory moments, and wires those moments into a graph.
  """

  alias SpectreMnemonic.Intake.{Extraction, Memory, Packet, PlugPipeline}
  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Memory.{Association, Moment, Secret, Signal}
  alias SpectreMnemonic.Result

  @default_chunk_words 180
  @default_overlap_words 40
  @default_summary_words 36
  @default_similarity_threshold 0.18
  @default_cross_memory_similarity_threshold 0.24
  @default_max_related_edges 40
  @default_max_cross_memory_edges 20

  @type envelope :: Memory.t()

  @doc "Runs unified active-first memory intake."
  @spec remember(term(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  def remember(input, opts \\ []) do
    with {:ok, memory} <- normalize(input, opts),
         memory <- attach_recent_moments(memory),
         {:ok, memory} <- run_plugs(memory, opts) do
      dispatch_memory(memory, opts)
    else
      {:halt, %Memory{} = memory} -> dispatch_memory(memory, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec dispatch_memory(Memory.t(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  defp dispatch_memory(%Memory{result: nil, secret?: true} = memory, opts),
    do: remember_secret(memory, opts)

  defp dispatch_memory(%Memory{result: nil} = memory, opts), do: remember_public(memory, opts)

  defp dispatch_memory(%Memory{result: result} = memory, _opts),
    do: normalize_result(result, memory)

  @spec remember_public(Memory.t(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  defp remember_public(%Memory{} = memory, opts) do
    with {:ok, root_result} <- record_root(memory, opts),
         {:ok, chunk_results} <- record_chunks(memory, root_result.moment, opts),
         {:ok, summary_results} <-
           record_summaries(memory, root_result.moment, chunk_results, opts),
         {:ok, category_results} <-
           record_categories(memory, root_result.moment, chunk_results, summary_results, opts),
         {:ok, extraction_results, extraction_associations} <-
           record_extraction(memory, root_result.moment, opts),
         {:ok, associations} <-
           link_graph(
             root_result.moment,
             chunk_results,
             summary_results,
             category_results,
             opts
           ) do
      results =
        [root_result] ++
          chunk_results ++ summary_results ++ category_results ++ extraction_results

      {:ok,
       %Packet{
         root: root_result.moment,
         events: Enum.map(results, & &1.signal),
         moments: Enum.map(results, & &1.moment),
         chunks: Enum.map(chunk_results, & &1.moment),
         summaries: Enum.map(summary_results, & &1.moment),
         categories: Enum.map(category_results, & &1.moment),
         associations: associations ++ extraction_associations,
         warnings: memory.warnings,
         errors: memory.errors,
         persistence: persistence_status(opts)
       }}
    end
  end

  @spec remember_secret(Memory.t(), keyword()) :: {:ok, Packet.t()} | {:error, term()}
  defp remember_secret(%Memory{} = memory, opts) do
    with {:ok, result} <-
           SpectreMnemonic.signal(
             memory.text,
             opts
             |> Keyword.put(:secret?, true)
             |> Keyword.put(:label, memory.label || "secret")
             |> Keyword.put(:metadata, memory.metadata)
             |> Keyword.put(:stream, memory.stream)
             |> Keyword.put(:task_id, memory.task_id)
             |> Keyword.put_new(:kind, :secret)
             |> Keyword.put_new(:persist?, true)
           ) do
      {:ok,
       %Packet{
         root: result.moment,
         events: [result.signal],
         moments: [result.moment],
         chunks: [],
         summaries: [],
         categories: [],
         associations: [],
         warnings: memory.warnings,
         errors: memory.errors,
         persistence: persistence_status(Keyword.put_new(opts, :persist?, true))
       }}
    end
  end

  @spec normalize(term(), keyword()) :: {:ok, Memory.t()} | {:error, :empty_memory}
  defp normalize(input, opts) do
    text = text_projection(input)

    if String.trim(text) == "" do
      {:error, :empty_memory}
    else
      kind = Keyword.get(opts, :kind) || input_kind(input) || infer_kind(input, text)
      metadata = input_metadata(input) |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))

      {:ok,
       %Memory{
         input: input,
         text: text,
         kind: kind,
         stream: Keyword.get(opts, :stream) || infer_stream(kind),
         task_id: Keyword.get(opts, :task_id) || metadata_value(input, :task_id),
         metadata: metadata,
         tags: List.wrap(Keyword.get(opts, :tags) || metadata_value(input, :tags) || []),
         title: Keyword.get(opts, :title) || title_for(input, text, kind),
         secret?: false,
         label: nil
       }}
    end
  end

  @spec run_plugs(Memory.t(), keyword()) ::
          {:ok, Memory.t()} | {:halt, Memory.t()} | {:error, term()}
  defp run_plugs(%Memory{} = memory, opts), do: PlugPipeline.run(memory, opts)

  @spec attach_recent_moments(Memory.t()) :: Memory.t()
  defp attach_recent_moments(%Memory{} = memory) do
    recent = SpectreMnemonic.Active.Focus.recent_moments(memory.stream, memory.task_id, 12)
    %{memory | recent_moments: recent}
  end

  @spec normalize_result(term(), Memory.t()) :: {:ok, Packet.t()} | {:error, term()}
  defp normalize_result({:ok, result}, memory), do: normalize_result(result, memory)
  defp normalize_result(%Packet{} = packet, _memory), do: {:ok, packet}

  defp normalize_result(%Moment{} = moment, memory) do
    {:ok,
     %Packet{
       root: moment,
       moments: [moment],
       warnings: memory.warnings,
       errors: memory.errors,
       persistence: %{mode: :plug, durable?: false}
     }}
  end

  defp normalize_result(%Secret{} = secret, memory) do
    {:ok,
     %Packet{
       root: secret,
       moments: [secret],
       warnings: memory.warnings,
       errors: memory.errors,
       persistence: %{mode: :plug, durable?: false}
     }}
  end

  defp normalize_result(%Signal{} = signal, memory) do
    {:ok,
     %Packet{
       events: [signal],
       warnings: memory.warnings,
       errors: memory.errors,
       persistence: %{mode: :plug, durable?: false}
     }}
  end

  defp normalize_result(other, _memory), do: {:error, {:invalid_plug_result, other}}

  @spec record_root(envelope(), keyword()) ::
          {:ok, %{signal: Signal.t(), moment: Moment.t() | Secret.t()}} | {:error, term()}
  defp record_root(envelope, opts) do
    SpectreMnemonic.signal(root_text(envelope),
      stream: envelope.stream,
      kind: envelope.kind,
      task_id: envelope.task_id,
      attention: Keyword.get(opts, :root_attention, 2.0),
      persist?: Keyword.get(opts, :persist?, false),
      metadata:
        envelope.metadata
        |> Map.merge(%{
          intake_role: :root,
          title: envelope.title,
          original_kind: envelope.kind,
          source: Keyword.get(opts, :source) || Map.get(envelope.metadata, :source),
          tags: envelope.tags,
          text_bytes: byte_size(envelope.text)
        })
    )
  end

  @spec record_chunks(envelope(), Moment.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp record_chunks(envelope, root, opts) do
    envelope.text
    |> chunk_text(chunk_words(opts), overlap_words(opts))
    |> Enum.with_index(1)
    |> Result.collect_ok(fn {chunk, index} ->
      metadata =
        envelope.metadata
        |> Map.merge(%{
          intake_role: :chunk,
          root_memory_id: root.id,
          source_task_id: envelope.task_id,
          chunk_index: index,
          word_count: length(words(chunk)),
          categories: categories_for(chunk)
        })

      case SpectreMnemonic.signal(chunk,
             stream: envelope.stream,
             kind: :memory_chunk,
             task_id: nil,
             attention: Keyword.get(opts, :chunk_attention, 1.0),
             persist?: Keyword.get(opts, :persist?, false),
             metadata: metadata
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec record_summaries(envelope(), Moment.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp record_summaries(envelope, root, chunk_results, opts) do
    chunk_summaries =
      Result.collect_ok(chunk_results, fn %{moment: chunk} ->
        record_summary(:chunk, chunk.text, root, envelope, opts,
          chunk_memory_id: chunk.id,
          chunk_index: chunk.metadata.chunk_index
        )
      end)

    with {:ok, summaries} <- chunk_summaries do
      combined = Enum.map_join(summaries, "\n", & &1.moment.text)

      case record_summary(:root, combined, root, envelope, opts) do
        {:ok, root_summary} -> {:ok, summaries ++ [root_summary]}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec record_summary(atom(), binary(), Moment.t(), envelope(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp record_summary(scope, text, root, envelope, opts, metadata_opts \\ []) do
    metadata = %{
      intake_role: :summary,
      summary_scope: scope,
      root_memory_id: root.id,
      source_task_id: envelope.task_id,
      title: envelope.title
    }

    summary = summarize(scope, text, opts)

    SpectreMnemonic.signal(summary.text,
      stream: envelope.stream,
      kind: :memory_summary,
      task_id: nil,
      attention: Keyword.get(opts, :summary_attention, 1.5),
      persist?: Keyword.get(opts, :persist?, false),
      metadata:
        envelope.metadata
        |> Map.merge(metadata)
        |> Map.merge(Map.new(metadata_opts))
        |> Map.merge(%{
          key_points: summary.key_points,
          entities: summary.entities,
          categories: summary.categories,
          relations: summary.relations,
          confidence: summary.confidence,
          summary_provider: summary.metadata
        })
    )
  end

  @spec record_categories(envelope(), Moment.t(), [map()], [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp record_categories(envelope, root, chunk_results, summary_results, opts) do
    labels =
      (chunk_results ++ summary_results)
      |> Enum.flat_map(&Map.get(&1.moment.metadata, :categories, []))
      |> Enum.concat([envelope.kind])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Result.collect_ok(labels, fn label ->
      case SpectreMnemonic.signal("Category: #{label}",
             stream: envelope.stream,
             kind: :memory_category,
             task_id: nil,
             attention: Keyword.get(opts, :category_attention, 1.1),
             persist?: Keyword.get(opts, :persist?, false),
             metadata:
               envelope.metadata
               |> Map.merge(%{
                 intake_role: :category,
                 root_memory_id: root.id,
                 source_task_id: envelope.task_id,
                 category: label
               })
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec record_extraction(envelope(), Moment.t(), keyword()) ::
          {:ok, [map()], [Association.t()]} | {:error, term()}
  defp record_extraction(envelope, root, opts) do
    if Keyword.get(opts, :extract_entities?, true) do
      with {:ok, graph} <-
             Extraction.extract(
               envelope.text,
               opts
               |> Keyword.put(:input, envelope.input)
               |> Keyword.put(:stream, envelope.stream)
               |> Keyword.put(:task_id, envelope.task_id)
             ),
           {:ok, results} <- record_extraction_nodes(graph, root, envelope, opts),
           {:ok, associations} <- link_extraction_graph(graph, root, results, opts) do
        {:ok, results, associations}
      end
    else
      {:ok, [], []}
    end
  end

  @spec record_extraction_nodes(map(), Moment.t(), envelope(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp record_extraction_nodes(graph, root, envelope, opts) do
    graph
    |> extraction_items()
    |> Result.collect_ok(fn {local_id, text, kind, metadata, attention} ->
      metadata =
        envelope.metadata
        |> Map.merge(metadata)
        |> Map.merge(%{
          intake_role: :extracted_fact,
          root_memory_id: root.id,
          source_task_id: envelope.task_id,
          extraction_local_id: local_id,
          extraction_provider: Map.get(graph.metadata, :provider)
        })

      case SpectreMnemonic.signal(text,
             stream: envelope.stream,
             kind: kind,
             task_id: nil,
             attention: Keyword.get(opts, :extraction_attention, attention),
             persist?: Keyword.get(opts, :persist?, false),
             metadata: metadata
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec extraction_items(map()) :: [{binary(), binary(), atom(), map(), number()}]
  defp extraction_items(graph) do
    entity_items(graph.entities) ++
      event_items(graph.events) ++
      time_items(graph.times) ++
      value_items(graph.values)
  end

  @spec entity_items([map()]) :: [{binary(), binary(), atom(), map(), number()}]
  defp entity_items(entities) do
    Enum.map(entities, fn entity ->
      metadata = %{
        extraction_role: :entity,
        canonical: entity.canonical,
        aliases: entity.aliases,
        entity_type: entity.type,
        language: entity.language,
        confidence: entity.confidence,
        categories: [:entity]
      }

      {entity.id, "Entity: #{entity.name}", :memory_entity, metadata, 1.6}
    end)
  end

  @spec event_items([map()]) :: [{binary(), binary(), atom(), map(), number()}]
  defp event_items(events) do
    Enum.map(events, fn event ->
      metadata = %{
        extraction_role: :event,
        action: event.action,
        actor: event.actor,
        acted_on: event.acted_on,
        time: event.time,
        values: Map.get(event, :values, []),
        source_span: event.source_span,
        language: event.language,
        confidence: event.confidence,
        categories: [:event]
      }

      {event.id, "Event: #{event.text}", :memory_event, metadata, 1.8}
    end)
  end

  @spec time_items([map()]) :: [{binary(), binary(), atom(), map(), number()}]
  defp time_items(times) do
    Enum.map(times, fn time ->
      metadata = %{
        extraction_role: :time,
        time_kind: time.kind,
        normalized_value: time.value,
        confidence: time.confidence,
        categories: [:time]
      }

      {time.id, "Time: #{time.value}", :memory_time, metadata, 1.4}
    end)
  end

  @spec value_items([map()]) :: [{binary(), binary(), atom(), map(), number()}]
  defp value_items(values) do
    Enum.map(values, fn value ->
      metadata = %{
        extraction_role: :value,
        value_kind: value.kind,
        value: stored_value(value),
        display: value.display,
        entity: value.entity,
        sensitive?: value.sensitive?,
        raw_value?: value.raw_value?,
        confidence: value.confidence,
        categories: [:value]
      }

      {value.id, "Value: #{value.kind} #{value.display}", :memory_value, metadata, 1.4}
    end)
  end

  @spec stored_value(map()) :: binary() | nil
  defp stored_value(%{sensitive?: true, raw_value?: false}), do: nil
  defp stored_value(%{value: value}), do: value

  @spec link_extraction_graph(map(), Moment.t(), [map()], keyword()) ::
          {:ok, [Association.t()]} | {:error, term()}
  defp link_extraction_graph(graph, root, results, opts) do
    node_by_local_id = Map.new(results, &{&1.moment.metadata.extraction_local_id, &1.moment})

    planned_edges =
      observed_edges(root, Map.values(node_by_local_id)) ++
        mention_edges(root, graph.entities, node_by_local_id) ++
        relation_edges(graph.relations, node_by_local_id) ++
        event_field_edges(graph.events, node_by_local_id) ++
        value_entity_edges(graph.values, node_by_local_id) ++
        same_entity_edges(graph.entities, node_by_local_id)

    planned_edges
    |> Enum.uniq_by(fn {source, relation, target, _edge_opts} ->
      {source.id, relation, target.id}
    end)
    |> Result.collect_ok(fn {source, relation, target, edge_opts} ->
      case SpectreMnemonic.link(
             source.id,
             relation,
             target.id,
             Keyword.put_new(edge_opts, :persist?, Keyword.get(opts, :persist?, false))
           ) do
        {:ok, edge} -> {:ok, edge}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec observed_edges(Moment.t(), [Moment.t()]) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp observed_edges(root, moments) do
    Enum.map(moments, &{&1, :observed_in, root, [weight: 0.6]})
  end

  @spec mention_edges(Moment.t(), [map()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp mention_edges(root, entities, node_by_local_id) do
    entities
    |> Enum.flat_map(fn entity ->
      case Map.get(node_by_local_id, entity.id) do
        nil -> []
        moment -> [{root, :mentions_entity, moment, [weight: entity.confidence]}]
      end
    end)
  end

  @spec relation_edges([map()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp relation_edges(relations, node_by_local_id) do
    relations
    |> Enum.flat_map(fn relation ->
      with source when not is_nil(source) <- Map.get(node_by_local_id, relation.source),
           target when not is_nil(target) <- Map.get(node_by_local_id, relation.target) do
        [
          {source, relation.relation, target,
           [weight: relation.weight, metadata: relation.metadata]}
        ]
      else
        _missing -> []
      end
    end)
  end

  @spec event_field_edges([map()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp event_field_edges(events, node_by_local_id) do
    Enum.flat_map(events, fn event ->
      event_moment = Map.get(node_by_local_id, event.id)

      [
        {event_moment, :actor, Map.get(node_by_local_id, event.actor), [weight: 1.0]},
        {event_moment, :acted_on, Map.get(node_by_local_id, event.acted_on), [weight: 0.9]},
        {event_moment, :happened_at, Map.get(node_by_local_id, event.time), [weight: 0.9]}
      ]
      |> Enum.reject(fn {source, _relation, target, _opts} ->
        is_nil(source) or is_nil(target)
      end)
    end)
  end

  @spec value_entity_edges([map()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp value_entity_edges(values, node_by_local_id) do
    values
    |> Enum.flat_map(fn value ->
      with entity when not is_nil(entity) <- Map.get(node_by_local_id, value.entity),
           value_moment when not is_nil(value_moment) <- Map.get(node_by_local_id, value.id) do
        [{entity, :has_value, value_moment, [weight: value.confidence]}]
      else
        _missing -> []
      end
    end)
  end

  @spec same_entity_edges([map()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp same_entity_edges(entities, node_by_local_id) do
    current_ids = MapSet.new(Enum.map(node_by_local_id, fn {_local_id, moment} -> moment.id end))

    Enum.flat_map(entities, fn entity ->
      current = Map.get(node_by_local_id, entity.id)

      Focus.moments()
      |> Enum.filter(&(&1.kind == :memory_entity))
      |> Enum.reject(&MapSet.member?(current_ids, &1.id))
      |> Enum.filter(&(Map.get(&1.metadata, :canonical) == entity.canonical))
      |> Enum.flat_map(fn existing ->
        if current do
          [{current, :same_entity, existing, [weight: 1.0]}]
        else
          []
        end
      end)
    end)
  end

  @spec link_graph(Moment.t(), [map()], [map()], [map()], keyword()) ::
          {:ok, [Association.t()]} | {:error, term()}
  defp link_graph(root, chunk_results, summary_results, category_results, opts) do
    chunks = Enum.map(chunk_results, & &1.moment)
    summaries = Enum.map(summary_results, & &1.moment)
    categories = Enum.map(category_results, & &1.moment)

    category_by_label = Map.new(categories, &{&1.metadata.category, &1})

    planned_edges =
      Enum.map(chunks, &{root, :contains_chunk, &1, []}) ++
        Enum.map(summaries, &{root, :has_summary, &1, []}) ++
        Enum.map(categories, &{root, :has_category, &1, []}) ++
        chunk_summary_edges(chunks, summaries) ++
        sequence_edges(chunks, :next_chunk, :previous_chunk) ++
        category_edges(chunks ++ summaries, category_by_label) ++
        related_chunk_edges(chunks, opts) ++
        cross_memory_edges(root, chunks, summaries, categories, opts)

    Result.collect_ok(planned_edges, fn {source, relation, target, edge_opts} ->
      case SpectreMnemonic.link(
             source.id,
             relation,
             target.id,
             Keyword.put_new(edge_opts, :persist?, Keyword.get(opts, :persist?, false))
           ) do
        {:ok, edge} -> {:ok, edge}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec chunk_summary_edges([Moment.t()], [Moment.t()]) :: [
          {Moment.t(), atom(), Moment.t(), keyword()}
        ]
  defp chunk_summary_edges(chunks, summaries) do
    summaries
    |> Enum.filter(&(&1.metadata.summary_scope == :chunk))
    |> Enum.flat_map(fn summary ->
      case Enum.find(chunks, &(&1.id == summary.metadata.chunk_memory_id)) do
        nil -> []
        chunk -> [{chunk, :has_summary, summary, []}, {summary, :summarizes, chunk, []}]
      end
    end)
  end

  @spec sequence_edges([Moment.t()], atom(), atom()) :: [
          {Moment.t(), atom(), Moment.t(), keyword()}
        ]
  defp sequence_edges(items, forward, backward) do
    items
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [left, right] ->
      [{left, forward, right, []}, {right, backward, left, []}]
    end)
  end

  @spec category_edges([Moment.t()], map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp category_edges(moments, category_by_label) do
    Enum.flat_map(moments, &moment_category_edges(&1, category_by_label))
  end

  @spec moment_category_edges(Moment.t(), map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp moment_category_edges(moment, category_by_label) do
    moment.metadata
    |> Map.get(:categories, [])
    |> Enum.flat_map(&category_edge(moment, &1, category_by_label))
  end

  @spec category_edge(Moment.t(), term(), map()) :: [{Moment.t(), atom(), Moment.t(), keyword()}]
  defp category_edge(moment, label, category_by_label) do
    case Map.get(category_by_label, label) do
      nil -> []
      category -> [{moment, :categorized_as, category, [weight: 0.8]}]
    end
  end

  @spec related_chunk_edges([Moment.t()], keyword()) :: [
          {Moment.t(), atom(), Moment.t(), keyword()}
        ]
  defp related_chunk_edges(chunks, opts) do
    threshold = Keyword.get(opts, :similarity_threshold, @default_similarity_threshold)
    max_edges = Keyword.get(opts, :max_related_edges, @default_max_related_edges)

    for {left, left_index} <- Enum.with_index(chunks),
        {right, right_index} <- Enum.with_index(chunks),
        left_index < right_index,
        score = keyword_similarity(left, right),
        score >= threshold do
      {left, :related_chunk, right, [weight: score, metadata: %{similarity: score}]}
    end
    |> Enum.sort_by(fn {_left, _relation, _right, edge_opts} ->
      -Keyword.fetch!(edge_opts, :weight)
    end)
    |> Enum.take(max_edges)
  end

  @spec cross_memory_edges(Moment.t(), [Moment.t()], [Moment.t()], [Moment.t()], keyword()) :: [
          {Moment.t(), atom(), Moment.t(), keyword()}
        ]
  defp cross_memory_edges(root, chunks, summaries, categories, opts) do
    if Keyword.get(opts, :cross_memory?, true) do
      threshold =
        Keyword.get(
          opts,
          :cross_memory_similarity_threshold,
          @default_cross_memory_similarity_threshold
        )

      max_edges = Keyword.get(opts, :max_cross_memory_edges, @default_max_cross_memory_edges)
      current_ids = MapSet.new(Enum.map([root | chunks ++ summaries ++ categories], & &1.id))
      existing_edges = existing_cross_memory_edges(current_ids)
      anchors = [root | chunks] |> Enum.filter(&linkable_memory?/1)

      Focus.moments()
      |> Enum.reject(&(MapSet.member?(current_ids, &1.id) or not linkable_memory?(&1)))
      |> cross_memory_candidates(anchors, threshold, existing_edges)
      |> Enum.sort_by(fn {_source, _target, score} -> -score end)
      |> Enum.take(max_edges)
      |> Enum.map(fn {source, target, score} ->
        metadata = %{similarity: score, scope: :cross_memory}
        {source, :related_memory, target, [weight: score, metadata: metadata]}
      end)
    else
      []
    end
  end

  @spec existing_cross_memory_edges(MapSet.t(binary())) :: MapSet.t()
  defp existing_cross_memory_edges(current_ids) do
    current_ids
    |> Focus.associations_for_ids()
    |> Enum.filter(&(&1.relation == :related_memory))
    |> Enum.reduce(MapSet.new(), fn assoc, acc ->
      acc
      |> MapSet.put({assoc.source_id, assoc.target_id})
      |> MapSet.put({assoc.target_id, assoc.source_id})
    end)
  end

  @spec cross_memory_candidates([Moment.t()], [Moment.t()], float(), MapSet.t()) :: [
          {Moment.t(), Moment.t(), float()}
        ]
  defp cross_memory_candidates(candidates, anchors, threshold, existing_edges) do
    for source <- anchors,
        target <- candidates,
        not MapSet.member?(existing_edges, {source.id, target.id}),
        score = relationship_score(source, target),
        score >= threshold do
      {source, target, score}
    end
  end

  @spec linkable_memory?(Moment.t()) :: boolean()
  defp linkable_memory?(%{kind: :memory_category}), do: false
  defp linkable_memory?(_moment), do: true

  @spec relationship_score(Moment.t(), Moment.t()) :: float()
  defp relationship_score(left, right) do
    keyword_score = keyword_similarity(left, right)
    entity_score = set_similarity(left.entities, right.entities)
    category_score = metadata_category_similarity(left, right)
    task_bonus = if left.task_id && left.task_id == right.task_id, do: 0.12, else: 0.0

    min(1.0, max(keyword_score, entity_score) + category_score * 0.25 + task_bonus)
  end

  @spec metadata_category_similarity(Moment.t(), Moment.t()) :: float()
  defp metadata_category_similarity(left, right) do
    left_categories = Map.get(left.metadata, :categories, [])
    right_categories = Map.get(right.metadata, :categories, [])
    set_similarity(left_categories, right_categories)
  end

  @spec text_projection(term()) :: binary()
  defp text_projection(input) when is_binary(input), do: input
  defp text_projection(input), do: inspect(input, pretty: true, limit: :infinity)

  @spec input_kind(term()) :: atom() | nil
  defp input_kind(input) when is_map(input),
    do: metadata_value(input, :kind) || metadata_value(input, :type)

  defp input_kind(_input), do: nil

  @spec infer_kind(term(), binary()) :: atom()
  defp infer_kind(input, _text) when is_map(input) or is_list(input), do: :structured_event

  defp infer_kind(_input, text) do
    normalized = String.downcase(text)

    cond do
      json_looking?(text) -> :text
      code_like?(text) -> :code
      Regex.match?(~r/\b(todo|task|action item|next step|implement|verify)\b/i, text) -> :task
      Regex.match?(~r/\b(user|assistant|system):/i, text) -> :chat
      String.contains?(normalized, "prompt") -> :prompt
      true -> :text
    end
  end

  @spec infer_stream(atom()) :: atom()
  defp infer_stream(:task), do: :planning
  defp infer_stream(:chat), do: :chat
  defp infer_stream(:code), do: :code_learning
  defp infer_stream(:prompt), do: :chat
  defp infer_stream(_kind), do: :memory

  @spec input_metadata(term()) :: map()
  defp input_metadata(input) when is_map(input) do
    case metadata_value(input, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp input_metadata(_input), do: %{}

  @spec metadata_value(term(), atom()) :: term()
  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp metadata_value(_input, _key), do: nil

  @spec title_for(term(), binary(), atom()) :: binary()
  defp title_for(input, text, kind) when is_map(input) do
    metadata_value(input, :title) || metadata_value(input, :name) || title_for(nil, text, kind)
  end

  defp title_for(_input, text, kind) do
    text
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> "#{kind} memory"
      line -> String.slice(line, 0, 90)
    end
  end

  @spec root_text(envelope()) :: binary()
  defp root_text(envelope), do: "#{envelope.kind}: #{envelope.title}"

  @spec chunk_text(binary(), pos_integer(), non_neg_integer()) :: [binary()]
  defp chunk_text(text, chunk_size, overlap) do
    tokens = words(text)

    cond do
      tokens == [] ->
        [String.trim(text)]

      length(tokens) <= chunk_size ->
        [String.trim(text)]

      true ->
        step = max(1, chunk_size - overlap)

        tokens
        |> Stream.unfold(fn
          [] ->
            nil

          remaining ->
            chunk = Enum.take(remaining, chunk_size)
            next = Enum.drop(remaining, step)
            {Enum.join(chunk, " "), next}
        end)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @spec categories_for(binary()) :: [atom()]
  defp categories_for(text) do
    case categories(text) do
      [] -> [:note]
      categories -> categories
    end
  end

  @spec summarize(atom(), binary(), keyword()) :: map()
  defp summarize(scope, text, opts) do
    words = words(text)
    limit = opts |> Keyword.get(:summary_words, @default_summary_words) |> max(1)

    %{
      scope: scope,
      text: words |> Enum.take(limit) |> Enum.join(" "),
      key_points: key_points(text),
      entities: entities(text),
      categories: categories(text),
      relations: [],
      confidence: if(words == [], do: 0.0, else: 0.35),
      metadata: %{provider: :deterministic}
    }
  end

  @spec key_points(binary()) :: [binary()]
  defp key_points(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
  end

  @spec categories(binary()) :: [atom()]
  defp categories(text) do
    tokens = MapSet.new(words(text) |> Enum.map(&String.downcase/1))

    category_rules()
    |> Enum.filter(fn {_label, rule_words} ->
      Enum.any?(rule_words, &MapSet.member?(tokens, &1))
    end)
    |> Enum.map(fn {label, _rule_words} -> label end)
  end

  @spec category_rules :: [{atom(), [binary()]}]
  defp category_rules do
    [
      decision: ~w(decision decide decided choose chosen tradeoff because therefore),
      task: ~w(task todo action next must should implement build fix verify deadline),
      research: ~w(research evidence study source finding observed analysis hypothesis),
      error: ~w(error failure failed exception bug issue risk problem blocked),
      tool: ~w(tool command api endpoint script adapter integration function module),
      event: ~w(event happened meeting call update status timeline milestone),
      concept: ~w(concept definition means architecture design pattern model system)
    ]
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b[A-Z][A-Za-z0-9_]+\b/, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec keyword_similarity(Moment.t(), Moment.t()) :: float()
  defp keyword_similarity(left, right) do
    set_similarity(left.keywords, right.keywords)
  end

  @spec set_similarity([term()], [term()]) :: float()
  defp set_similarity(left, right) do
    left_items = MapSet.new(left)
    right_items = MapSet.new(right)
    union = MapSet.size(MapSet.union(left_items, right_items))

    if union == 0 do
      0.0
    else
      MapSet.size(MapSet.intersection(left_items, right_items)) / union
    end
  end

  @spec code_like?(binary()) :: boolean()
  defp code_like?(text) do
    Regex.match?(~r/\b(defmodule|def |defp |function|class|import|const|let|var)\b/, text) or
      Regex.match?(~r/[{};]\s*$/, String.trim(text))
  end

  @spec json_looking?(binary()) :: boolean()
  defp json_looking?(text) do
    trimmed = String.trim(text)

    (String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")) or
      (String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]"))
  end

  @spec chunk_words(keyword()) :: pos_integer()
  defp chunk_words(opts), do: opts |> Keyword.get(:chunk_words, @default_chunk_words) |> max(1)

  @spec overlap_words(keyword()) :: non_neg_integer()
  defp overlap_words(opts),
    do: opts |> Keyword.get(:overlap_words, @default_overlap_words) |> max(0)

  @spec words(binary()) :: [binary()]
  defp words(text) do
    Regex.scan(~r/[\p{L}\p{N}_'-]+/u, text)
    |> List.flatten()
  end

  @spec persistence_status(keyword()) :: map()
  defp persistence_status(opts) do
    if Keyword.get(opts, :persist?, false) do
      %{mode: :immediate, durable?: true}
    else
      %{mode: :active, durable?: false}
    end
  end
end
