defmodule SpectreMnemonic.Active.Validation do
  @moduledoc false

  @doc false
  @spec signal_options(keyword()) :: :ok | {:error, term()}
  def signal_options(opts) do
    with :ok <- structured_options(opts),
         :ok <- boolean_option(opts, :secret?),
         :ok <- number_option(opts, :attention) do
      number_option(opts, :confidence)
    end
  end

  @doc false
  @spec link_request(term(), term(), term(), keyword()) :: :ok | {:error, term()}
  def link_request(source_id, relation, target_id, opts) do
    with :ok <- link_endpoint(:source_id, source_id),
         :ok <- link_endpoint(:target_id, target_id),
         :ok <- link_relation(relation),
         :ok <- link_weight(Keyword.get(opts, :weight, 1.0)) do
      structured_options(opts)
    end
  end

  @spec link_endpoint(atom(), term()) :: :ok | {:error, term()}
  defp link_endpoint(_key, value) when is_binary(value) and value != "", do: :ok
  defp link_endpoint(key, value), do: {:error, {:invalid_link_endpoint, key, value}}

  @spec link_relation(term()) :: :ok | {:error, term()}
  defp link_relation(relation)
       when is_atom(relation) and relation not in [nil, true, false],
       do: :ok

  defp link_relation(relation), do: {:error, {:invalid_link_relation, relation}}

  @spec link_weight(term()) :: :ok | {:error, term()}
  defp link_weight(weight) when is_number(weight) and weight >= 0 and weight <= 1, do: :ok
  defp link_weight(weight), do: {:error, {:invalid_link_weight, weight}}

  @doc false
  @spec structured_options(keyword()) :: :ok | {:error, term()}
  def structured_options(opts) do
    with :ok <- map_option(opts, :metadata),
         :ok <- map_option(opts, :action_recipe_metadata),
         :ok <- boolean_option(opts, :persist?) do
      action_recipe(Keyword.get(opts, :action_recipe))
    end
  end

  @spec map_option(keyword(), atom()) :: :ok | {:error, term()}
  defp map_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        :ok

      {:ok, value} when is_list(value) ->
        if Keyword.keyword?(value),
          do: :ok,
          else: {:error, {:invalid_focus_option, key, value}}

      {:ok, value} ->
        {:error, {:invalid_focus_option, key, value}}
    end
  end

  @spec boolean_option(keyword(), atom()) :: :ok | {:error, term()}
  defp boolean_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> {:error, {:invalid_focus_option, key, value}}
    end
  end

  @spec number_option(keyword(), atom()) :: :ok | {:error, term()}
  defp number_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_number(value) -> :ok
      {:ok, value} -> {:error, {:invalid_focus_option, key, value}}
    end
  end

  @spec action_recipe(term()) :: :ok | {:error, term()}
  defp action_recipe(nil), do: :ok
  defp action_recipe(recipe) when is_binary(recipe) or is_map(recipe), do: :ok

  defp action_recipe(recipe) when is_list(recipe) do
    if Keyword.keyword?(recipe),
      do: :ok,
      else: {:error, {:invalid_focus_option, :action_recipe, recipe}}
  end

  defp action_recipe(recipe),
    do: {:error, {:invalid_focus_option, :action_recipe, recipe}}
end
