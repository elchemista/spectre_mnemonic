if Code.ensure_loaded?(Spectre.Stack.Installable) do
  defmodule Spectre.Mnemonic.ServerTool.Operations do
    @moduledoc false
    alias Spectre.GAM.Canonical.Value

    @reads %{
      recall: [:cue],
      search: [:cue],
      reflect: [:cue],
      search_observations: [:cue],
      search_mental_models: [:cue],
      search_knowledge: [:cue],
      knowledge: [],
      status: [:stream],
      atlas: []
    }
    @writes %{
      remember: [:observation],
      signal: [:observation],
      learn: [:observation],
      put_mental_model: [:observation],
      verify_observation: [:id],
      forget: [:selector],
      link: [:source_id, :relation, :target_id],
      merge_entities: [:winner_id, :loser_id],
      unmerge_entities: [:winner_id, :loser_id],
      consolidate: [],
      consolidate_observations: [],
      compact_knowledge: [],
      sweep_expired: []
    }
    @query_options ~w(limit max_tokens budget include_observations include_mental_models include_knowledge observation_limit mental_model_limit)a
    @write_options ~w(kind stream task_id tags metadata extract_entities?)a

    @doc false
    @spec reads() :: [atom()]
    def reads, do: Map.keys(@reads)

    @doc false
    @spec writes() :: [atom()]
    def writes, do: Map.keys(@writes)

    @doc false
    @spec fields(atom()) :: [atom()] | nil
    def fields(operation), do: Map.get(Map.merge(@reads, @writes), operation)

    @doc false
    @spec prepare(atom(), list()) :: {:ok, map()} | {:error, term()}
    def prepare(operation, payload) do
      with fields when is_list(fields) <- fields(operation),
           {:ok, values, opts} <- split(payload, length(fields)),
           :ok <- validate_options(operation, opts),
           true <- Enum.zip(fields, values) |> Enum.all?(&valid_argument?/1),
           :ok <- Value.validate({values, opts}) do
        request = Map.new(Enum.zip(fields, values))
        {:ok, if(opts == [], do: request, else: Map.put(request, :options, opts))}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_mnemonic_request}
      end
    end

    @doc false
    @spec validate_options(atom(), term()) :: :ok | {:error, term()}
    def validate_options(operation, opts) do
      if Keyword.keyword?(opts) and
           length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
           Enum.all?(opts, fn {key, value} ->
             key in allowed_options(operation) and valid_option?(key, value)
           end),
         do: :ok,
         else: {:error, :invalid_mnemonic_options}
    end

    @spec split(list(), non_neg_integer()) :: {:ok, list(), keyword()} | {:error, atom()}
    defp split(payload, arity) when length(payload) == arity, do: {:ok, payload, []}

    defp split(payload, arity) when length(payload) == arity + 1 do
      {values, [opts]} = Enum.split(payload, arity)
      if is_list(opts), do: {:ok, values, opts}, else: {:error, :invalid_mnemonic_options}
    end

    defp split(_, _), do: {:error, :invalid_mnemonic_request}

    @spec allowed_options(atom()) :: [atom()]
    defp allowed_options(operation) when operation in [:recall, :search, :reflect],
      do: @query_options

    defp allowed_options(operation)
         when operation in [
                :search_observations,
                :search_mental_models,
                :search_knowledge
              ],
         do: [:limit]

    defp allowed_options(:atlas), do: [:max_nodes, :max_edges]
    defp allowed_options(operation) when operation in [:remember, :signal], do: @write_options
    defp allowed_options(:learn), do: [:name, :metadata]
    defp allowed_options(:verify_observation), do: [:relation, :source_id, :confidence_delta]
    defp allowed_options(:consolidate), do: [:min_attention]
    defp allowed_options(:compact_knowledge), do: []
    defp allowed_options(_), do: []

    @spec valid_argument?({atom(), term()}) :: boolean()
    defp valid_argument?({:observation, value}),
      do: is_binary(value) or (is_map(value) and not is_struct(value))

    defp valid_argument?({:cue, value}),
      do: is_binary(value) or (is_map(value) and not is_struct(value))

    defp valid_argument?({:relation, value}),
      do: value in [:supports, :weakens, :contradicts, :related_to, :depends_on, :same_as]

    defp valid_argument?({:selector, {kind, value}}),
      do: kind in [:stream, :task] and (is_binary(value) or is_atom(value))

    defp valid_argument?({:stream, value}), do: is_binary(value) or is_atom(value)
    defp valid_argument?({_, value}), do: is_binary(value) and value != ""

    @spec valid_option?(atom(), term()) :: boolean()
    defp valid_option?(key, value)
         when key in [:limit, :observation_limit, :mental_model_limit, :max_nodes, :max_edges],
         do: is_integer(value) and value > 0 and value <= 1000

    defp valid_option?(:max_tokens, value),
      do: is_integer(value) and value > 0 and value <= 100_000

    defp valid_option?(:budget, value), do: value in [:low, :mid, :high]

    defp valid_option?(key, value)
         when key in [
                :include_observations,
                :include_mental_models,
                :include_knowledge,
                :extract_entities?
              ],
         do: is_boolean(value)

    defp valid_option?(:relation, value), do: value in [:supports, :weakens, :contradicts]

    defp valid_option?(key, value) when key in [:min_attention, :confidence_delta],
      do: is_number(value) and value >= 0 and value <= 1

    defp valid_option?(:metadata, value), do: is_map(value) and not is_struct(value)

    defp valid_option?(:tags, value),
      do: is_list(value) and Enum.all?(value, &(is_binary(&1) or is_atom(&1)))

    defp valid_option?(key, value) when key in [:name, :source_id, :task_id], do: is_binary(value)

    defp valid_option?(key, value) when key in [:kind, :stream],
      do: is_binary(value) or is_atom(value)

    defp valid_option?(_, _), do: false
  end
end
