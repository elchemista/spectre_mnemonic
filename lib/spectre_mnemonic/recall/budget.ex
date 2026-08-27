defmodule SpectreMnemonic.Recall.Budget do
  @moduledoc false

  @doc false
  @spec profile(keyword()) :: map()
  def profile(opts) do
    case Keyword.get(opts, :budget, :mid) do
      :low ->
        %{
          seed_multiplier: 1,
          graph_depth: 1,
          hop_decay: 0.62,
          activation_floor: 0.14,
          max_graph_nodes: 60
        }

      :high ->
        %{
          seed_multiplier: 4,
          graph_depth: 3,
          hop_decay: 0.78,
          activation_floor: 0.045,
          max_graph_nodes: 400
        }

      _mid ->
        %{
          seed_multiplier: 2,
          graph_depth: 2,
          hop_decay: 0.72,
          activation_floor: 0.08,
          max_graph_nodes: 200
        }
    end
  end

  @doc false
  @spec apply_primary([term()], [term()], [term()], keyword(), non_neg_integer()) ::
          {map(), non_neg_integer() | nil}
  def apply_primary(moments, observations, mental_models, opts, limit) do
    case max_tokens(opts) do
      nil ->
        {%{
           moments: Enum.take(moments, limit),
           observations: observations,
           mental_models: mental_models,
           knowledge: [],
           artifacts: [],
           associations: [],
           action_recipes: []
         }, nil}

      max_tokens ->
        groups = [
          {:mental_models, mental_models},
          {:observations, observations},
          {:moments, Enum.take(moments, limit)}
        ]

        {selected, used} = select_groups(groups, max_tokens, 0)

        {Map.merge(
           %{
             moments: [],
             observations: [],
             mental_models: [],
             knowledge: [],
             artifacts: [],
             associations: [],
             action_recipes: []
           },
           selected
         ), used}
    end
  end

  @doc false
  @spec apply_dependent(map(), [term()], [term()], [term()], [term()], keyword(), integer() | nil) ::
          {map(), non_neg_integer() | nil}
  def apply_dependent(
        components,
        artifacts,
        associations,
        action_recipes,
        knowledge,
        _opts,
        nil
      ) do
    {%{
       components
       | artifacts: artifacts,
         associations: associations,
         action_recipes: action_recipes,
         knowledge: knowledge
     }, nil}
  end

  def apply_dependent(
        components,
        artifacts,
        associations,
        action_recipes,
        knowledge,
        opts,
        used
      ) do
    groups = [
      {:associations, associations},
      {:artifacts, artifacts},
      {:action_recipes, action_recipes},
      {:knowledge, knowledge}
    ]

    {selected, used} = select_groups(groups, max_tokens(opts), used)
    {Map.merge(components, selected), used}
  end

  @doc false
  @spec usage([term()], [term()], [term()], [term()], [term()], [term()], [term()], keyword()) ::
          map()
  def usage(
        moments,
        observations,
        mental_models,
        knowledge,
        artifacts,
        associations,
        action_recipes,
        opts
      ) do
    estimated =
      (mental_models ++
         observations ++
         moments ++
         knowledge ++
         artifacts ++
         associations ++
         action_recipes)
      |> Enum.map(&estimate_tokens(memory_text(&1)))
      |> Enum.sum()

    %{
      estimated_tokens: estimated,
      max_tokens: Keyword.get(opts, :max_tokens),
      budget: Keyword.get(opts, :budget, :mid)
    }
  end

  @spec select_groups([{atom(), [term()]}], pos_integer(), non_neg_integer()) ::
          {map(), non_neg_integer()}
  defp select_groups(groups, max_tokens, used) do
    Enum.reduce(groups, {%{}, used}, fn {key, items}, {selected, current_used} ->
      {selected_items, current_used} = select_items(items, max_tokens, current_used)
      {Map.put(selected, key, selected_items), current_used}
    end)
  end

  @spec select_items([term()], pos_integer(), non_neg_integer()) ::
          {[term()], non_neg_integer()}
  defp select_items(items, max_tokens, used) do
    items
    |> Enum.reduce_while({[], used}, fn item, {selected, current_used} ->
      cost = estimate_tokens(memory_text(item))

      cond do
        selected == [] and current_used == 0 and cost > max_tokens ->
          {:halt, {[item], current_used + cost}}

        current_used + cost <= max_tokens ->
          {:cont, {[item | selected], current_used + cost}}

        true ->
          {:halt, {selected, current_used}}
      end
    end)
    |> then(fn {selected, current_used} -> {Enum.reverse(selected), current_used} end)
  end

  @spec max_tokens(keyword()) :: pos_integer() | nil
  defp max_tokens(opts) do
    case Keyword.get(opts, :max_tokens) do
      max_tokens when is_integer(max_tokens) and max_tokens > 0 -> max_tokens
      _missing -> nil
    end
  end

  @spec memory_text(term()) :: binary()
  defp memory_text(%{text: text}) when is_binary(text), do: text
  defp memory_text(%{statement: statement}) when is_binary(statement), do: statement
  defp memory_text(%{answer: answer}) when is_binary(answer), do: answer
  defp memory_text(%{source: source}) when is_binary(source), do: source

  defp memory_text(%{relation: relation, source_id: source_id, target_id: target_id}) do
    "#{source_id} #{relation} #{target_id}"
  end

  defp memory_text(_memory), do: ""

  @spec estimate_tokens(binary()) :: pos_integer()
  defp estimate_tokens(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> length()
    |> Kernel.*(4)
    |> div(3)
    |> max(1)
  end
end
