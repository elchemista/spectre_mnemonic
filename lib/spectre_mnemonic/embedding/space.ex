defmodule SpectreMnemonic.Embedding.Space do
  @moduledoc "Stable identity and compatibility fence for one embedding space."

  @enforce_keys [:id]
  defstruct id: nil,
            provider: nil,
            model: nil,
            revision: nil,
            dimensions: nil,
            normalization: :l2,
            format: :f32,
            quantizer_version: 1

  @type t :: %__MODULE__{
          id: binary(),
          provider: term(),
          model: term(),
          revision: term(),
          dimensions: pos_integer() | nil,
          normalization: atom(),
          format: atom(),
          quantizer_version: pos_integer()
        }

  @doc "Builds a deterministic space descriptor from Engine embedding configuration."
  @spec new(term()) :: t()
  def new(%__MODULE__{} = space), do: space

  def new(config) do
    config = normalize_config(config)
    provider_config = provider_config(config)
    attributes = attributes(config, provider_config)
    struct(__MODULE__, Map.put(attributes, :id, space_id(config, attributes)))
  end

  @spec attributes(map(), map()) :: map()
  defp attributes(config, provider_config) do
    %{
      provider: first_value([{provider_config, :provider}, {config, :provider}]),
      model:
        first_value([
          {provider_config, :model_id},
          {provider_config, :model},
          {config, :model_id},
          {config, :model}
        ]),
      revision: first_value([{provider_config, :revision}, {config, :revision}]),
      dimensions: positive(first_value([{provider_config, :dimensions}, {config, :dimensions}])),
      normalization:
        first_value([{provider_config, :normalization}, {config, :normalization}]) || :l2,
      format: first_value([{provider_config, :format}, {config, :format}]) || :f32,
      quantizer_version:
        positive(
          first_value([
            {provider_config, :quantizer_version},
            {config, :quantizer_version}
          ])
        ) || 1
    }
  end

  @spec space_id(map(), map()) :: binary()
  defp space_id(config, attributes) do
    explicit = first_value([{config, :space_id}, {config, :id}])
    normalize_id(explicit) || derived_id(attributes)
  end

  @spec first_value([{map(), atom()}]) :: term()
  defp first_value(sources) do
    Enum.find_value(sources, fn {source, key} -> value(source, key) end)
  end

  @doc false
  @spec id(map() | nil, keyword()) :: binary()
  def id(metadata, opts \\ []) do
    metadata = if is_map(metadata), do: metadata, else: %{}

    cond do
      is_binary(value(metadata, :space_id)) and value(metadata, :space_id) != "" ->
        value(metadata, :space_id)

      embedding_identity_present?(metadata) ->
        metadata
        |> metadata_attributes()
        |> derived_id()

      match?(%__MODULE__{}, Keyword.get(opts, :embedding_space)) ->
        Keyword.fetch!(opts, :embedding_space).id

      true ->
        "default"
    end
  end

  @spec metadata_attributes(map()) :: map()
  defp metadata_attributes(metadata) do
    %{
      provider: value(metadata, :provider),
      model: value(metadata, :model),
      revision: value(metadata, :revision),
      dimensions: positive(value(metadata, :dimensions)),
      normalization: value(metadata, :normalization) || :l2,
      format: value(metadata, :format) || :f32,
      quantizer_version: positive(value(metadata, :quantizer_version)) || 1
    }
  end

  @spec embedding_identity_present?(map()) :: boolean()
  defp embedding_identity_present?(metadata) do
    Enum.any?([:provider, :model, :revision, :dimensions], &(not is_nil(value(metadata, &1))))
  end

  @spec derived_id(map()) :: binary()
  defp derived_id(attributes) do
    digest =
      attributes
      |> Map.take([
        :provider,
        :model,
        :revision,
        :dimensions,
        :normalization,
        :format,
        :quantizer_version
      ])
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "emb_" <> binary_part(digest, 0, 22)
  end

  @spec provider_config(map()) :: map()
  defp provider_config(config) do
    case value(config, :fast) do
      value when is_map(value) -> value
      value when is_list(value) -> normalize_config(value)
      _missing -> config
    end
  end

  @spec normalize_config(term()) :: map()
  defp normalize_config(value) when is_map(value), do: value

  defp normalize_config(value) when is_list(value) do
    if Keyword.keyword?(value), do: Map.new(value), else: %{}
  end

  defp normalize_config(_value), do: %{}

  @spec value(map(), atom()) :: term()
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec positive(term()) :: pos_integer() | nil
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  @spec normalize_id(term()) :: binary() | nil
  defp normalize_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_id(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalize_id(_value), do: nil
end
