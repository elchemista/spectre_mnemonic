defmodule SpectreMnemonic.MemoryIntake do
  @moduledoc """
  Unified intake pipeline behind `SpectreMnemonic.remember/2`.

  Intake accepts already-parsed information, keeps JSON-looking strings as text,
  creates active memory moments, and wires those moments into a graph.
  """

  alias SpectreMnemonic.{Association, MemoryPacket, Moment, Signal, Summarizer}

  @default_chunk_words 180
  @default_overlap_words 40
  @default_similarity_threshold 0.18
  @default_max_related_edges 40

  @type envelope :: %{
          input: term(),
          text: binary(),
          kind: atom(),
          stream: term(),
          task_id: term(),
          metadata: map(),
          tags: [term()],
          title: binary()
        }

  @doc "Runs unified active-first memory intake."
  @spec remember(term(), keyword()) :: {:ok, MemoryPacket.t()} | {:error, term()}
  def remember(input, opts \\ []) do
    with {:ok, envelope} <- normalize(input, opts),
         {:ok, root_result} <- record_root(envelope, opts),
         {:ok, chunk_results} <- record_chunks(envelope, root_result.moment, opts),
         {:ok, summary_results} <-
           record_summaries(envelope, root_result.moment, chunk_results, opts),
         {:ok, category_results} <-
           record_categories(envelope, root_result.moment, chunk_results, summary_results, opts),
         {:ok, associations} <-
           link_graph(root_result.moment, chunk_results, summary_results, category_results, opts) do
      results = [root_result] ++ chunk_results ++ summary_results ++ category_results

      {:ok,
       %MemoryPacket{
         root: root_result.moment,
         events: Enum.map(results, & &1.signal),
         moments: Enum.map(results, & &1.moment),
         chunks: Enum.map(chunk_results, & &1.moment),
         summaries: Enum.map(summary_results, & &1.moment),
         categories: Enum.map(category_results, & &1.moment),
         associations: associations,
         warnings: [],
         errors: [],
         persistence: persistence_status(opts)
       }}
    end
  end

  @spec normalize(term(), keyword()) :: {:ok, envelope()} | {:error, :empty_memory}
  defp normalize(input, opts) do
    text = text_projection(input)

    if String.trim(text) == "" do
      {:error, :empty_memory}
    else
      kind = Keyword.get(opts, :kind) || input_kind(input) || infer_kind(input, text)
      metadata = input_metadata(input) |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))

      {:ok,
       %{
         input: input,
         text: text,
         kind: kind,
         stream: Keyword.get(opts, :stream) || infer_stream(kind),
         task_id: Keyword.get(opts, :task_id) || metadata_value(input, :task_id),
         metadata: metadata,
         tags: List.wrap(Keyword.get(opts, :tags) || metadata_value(input, :tags) || []),
         title: Keyword.get(opts, :title) || title_for(input, text, kind)
       }}
    end
  end

  @spec record_root(envelope(), keyword()) ::
          {:ok, %{signal: Signal.t(), moment: Moment.t()}} | {:error, term()}
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
    |> Enum.reduce_while({:ok, []}, fn {chunk, index}, {:ok, acc} ->
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
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec record_summaries(envelope(), Moment.t(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp record_summaries(envelope, root, chunk_results, opts) do
    chunk_summaries =
      Enum.reduce_while(chunk_results, {:ok, []}, fn %{moment: chunk}, {:ok, acc} ->
        case record_summary(:chunk, chunk.text, root, envelope, opts,
               chunk_memory_id: chunk.id,
               chunk_index: chunk.metadata.chunk_index
             ) do
          {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
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

    with {:ok, summary} <-
           Summarizer.summarize(
             scope,
             text,
             Keyword.merge(opts, metadata: Map.merge(metadata, Map.new(metadata_opts)))
           ) do
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
            summarizer: summary.metadata
          })
      )
    end
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

    Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, acc} ->
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
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
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
        related_chunk_edges(chunks, opts)

    Enum.reduce_while(planned_edges, {:ok, []}, fn {source, relation, target, edge_opts},
                                                   {:ok, acc} ->
      case SpectreMnemonic.link(
             source.id,
             relation,
             target.id,
             Keyword.put_new(edge_opts, :persist?, Keyword.get(opts, :persist?, false))
           ) do
        {:ok, edge} -> {:cont, {:ok, acc ++ [edge]}}
        {:error, reason} -> {:halt, {:error, reason}}
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
    case Summarizer.summarize(:classification, text) do
      {:ok, %{categories: categories}} when categories != [] -> categories
      _other -> [:note]
    end
  end

  @spec keyword_similarity(Moment.t(), Moment.t()) :: float()
  defp keyword_similarity(left, right) do
    left_keywords = MapSet.new(left.keywords)
    right_keywords = MapSet.new(right.keywords)
    union = MapSet.size(MapSet.union(left_keywords, right_keywords))

    if union == 0 do
      0.0
    else
      MapSet.size(MapSet.intersection(left_keywords, right_keywords)) / union
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
