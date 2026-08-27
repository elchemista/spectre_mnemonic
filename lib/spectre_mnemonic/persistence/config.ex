defmodule SpectreMnemonic.Persistence.Config do
  @moduledoc false

  alias SpectreMnemonic.Persistence.Store.File, as: StoreFile
  alias SpectreMnemonic.Persistence.Store.Record

  @default_store_id :local_file

  @type store :: %{
          id: atom() | binary(),
          adapter: module(),
          role: atom() | nil,
          duplicate: boolean(),
          families: :all | [atom()],
          opts: keyword()
        }
  @type t :: keyword()

  @spec load() :: t()
  def load do
    configured =
      :spectre_mnemonic
      |> Application.get_env(:persistent_memory, [])
      |> normalize_keyword()

    defaults()
    |> merge(configured)
    |> ensure_stores()
  end

  @spec effective(keyword()) :: t()
  def effective(opts) do
    override = opts |> Keyword.get(:persistent_memory, []) |> normalize_keyword()

    load()
    |> merge(override)
    |> ensure_stores()
    |> normalize()
  end

  @spec defaults() :: t()
  def defaults do
    [
      write_mode: :all,
      read_mode: :smart,
      failure_mode: :strict,
      compact_mode: :physical,
      semantic_compact_families: [
        :moments,
        :knowledge,
        :observations,
        :mental_models,
        :summaries,
        :categories,
        :associations,
        :memory_states
      ],
      semantic_compact_limit: 1_000,
      stores: [
        [
          id: @default_store_id,
          adapter: StoreFile,
          role: :primary,
          duplicate: true,
          opts: [data_root: StoreFile.data_root()]
        ]
      ]
    ]
  end

  @spec normalize(t()) :: t()
  def normalize(config) do
    stores =
      config
      |> Keyword.get(:stores, [])
      |> Enum.map(&normalize_store/1)
      |> Enum.reject(&is_nil/1)
      |> default_stores_if_empty()
      |> ensure_primary_store()

    Keyword.put(config, :stores, stores)
  end

  @spec selected_stores(t(), Record.t()) :: [store()]
  def selected_stores(config, record) do
    stores = Keyword.fetch!(config, :stores)

    config
    |> Keyword.get(:write_mode, :all)
    |> do_selected_stores(stores, record)
    |> Enum.uniq_by(& &1.id)
  end

  @spec replayable_stores(t()) :: [store()]
  def replayable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store -> replay_supported?(store, safe_capabilities(store)) end)
  end

  @spec lookup_stores(t()) :: [store()]
  def lookup_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store -> :lookup in safe_capabilities(store) end)
  end

  @spec searchable_stores(t()) :: [store()]
  def searchable_stores(config) do
    config
    |> Keyword.fetch!(:stores)
    |> Enum.filter(fn store ->
      capabilities = safe_capabilities(store)
      Enum.any?([:search, :vector_search, :fulltext_search], &(&1 in capabilities))
    end)
  end

  @spec replay_supported?(store(), [SpectreMnemonic.Persistence.Store.Adapter.capability()]) ::
          boolean()
  def replay_supported?(store, capabilities) do
    (:replay_fold in capabilities and function_exported?(store.adapter, :replay_fold, 3)) or
      (:replay in capabilities and function_exported?(store.adapter, :replay, 1))
  end

  @spec safe_capabilities(store()) :: [SpectreMnemonic.Persistence.Store.Adapter.capability()]
  def safe_capabilities(store) do
    case store.adapter.capabilities(store.opts) do
      capabilities when is_list(capabilities) -> capabilities
      _invalid -> []
    end
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  @spec normalize_keyword(term()) :: keyword()
  def normalize_keyword(config) when is_map(config), do: Map.to_list(config)

  def normalize_keyword(config) when is_list(config) do
    if Keyword.keyword?(config), do: config, else: []
  end

  def normalize_keyword(_config), do: []

  defp merge(base, override) do
    Keyword.merge(base, override, fn
      :stores, _base, configured -> configured
      _key, _base, configured -> configured
    end)
  end

  defp ensure_stores(config) do
    case Keyword.get(config, :stores, []) do
      stores when is_list(stores) and stores != [] ->
        if Enum.all?(stores, &(is_map(&1) or is_list(&1))),
          do: config,
          else: Keyword.put(config, :stores, Keyword.fetch!(defaults(), :stores))

      _invalid ->
        Keyword.put(config, :stores, Keyword.fetch!(defaults(), :stores))
    end
  end

  defp normalize_store(store) do
    store = normalize_keyword(store)

    with {:ok, id} <- Keyword.fetch(store, :id),
         {:ok, adapter} when is_atom(adapter) <- Keyword.fetch(store, :adapter) do
      %{
        id: id,
        adapter: adapter,
        role: Keyword.get(store, :role),
        duplicate: Keyword.get(store, :duplicate, true),
        families: Keyword.get(store, :families, :all),
        opts: normalize_keyword(Keyword.get(store, :opts, []))
      }
    else
      _invalid -> nil
    end
  end

  defp default_stores_if_empty([]) do
    defaults()
    |> Keyword.fetch!(:stores)
    |> Enum.map(&normalize_store/1)
    |> Enum.reject(&is_nil/1)
  end

  defp default_stores_if_empty(stores), do: stores

  defp ensure_primary_store([]), do: []

  defp ensure_primary_store(stores) do
    if Enum.any?(stores, &(&1.role == :primary)) do
      stores
    else
      [first | rest] = stores
      [%{first | role: :primary} | rest]
    end
  end

  defp do_selected_stores(:all, stores, record) do
    Enum.filter(stores, fn store ->
      store.role == :primary or (store.duplicate and handles_family?(store, record.family))
    end)
  end

  defp do_selected_stores(:primary_only, stores, _record),
    do: Enum.filter(stores, &(&1.role == :primary))

  defp do_selected_stores({:families, rules}, stores, record) do
    routed_ids =
      rules
      |> Keyword.get(record.family, [])
      |> List.wrap()
      |> MapSet.new()

    Enum.filter(stores, fn store ->
      store.role == :primary or MapSet.member?(routed_ids, store.id)
    end)
  end

  defp do_selected_stores(_unknown, stores, record),
    do: do_selected_stores(:all, stores, record)

  defp handles_family?(%{families: :all}, _family), do: true
  defp handles_family?(%{families: families}, family), do: family in List.wrap(families)
end
