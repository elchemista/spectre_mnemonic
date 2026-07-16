defmodule SpectreMnemonic.Identity do
  @moduledoc """
  Stable identity and namespace helpers.

  Every running SpectreMnemonic instance must have a non-empty namespace. The
  namespace is stored beside durable records and used by all read paths; UUIDv7
  provides collision-resistant, time-sortable ids across restarts and nodes.
  """

  @typedoc "Stable application or agent namespace."
  @type namespace :: binary()

  @doc "Returns the configured application namespace."
  @spec configured_namespace() :: {:ok, namespace()} | {:error, :namespace_required}
  def configured_namespace do
    :spectre_mnemonic
    |> Application.get_env(:namespace)
    |> normalize_namespace()
  end

  @doc "Resolves an explicit namespace or the configured application namespace."
  @spec fetch_namespace(keyword()) ::
          {:ok, namespace()} | {:error, :namespace_required | {:namespace_mismatch, binary(), binary()}}
  def fetch_namespace(opts \\ []) do
    with {:ok, configured} <- configured_namespace() do
      case Keyword.fetch(opts, :namespace) do
        :error ->
          {:ok, configured}

        {:ok, namespace} ->
          with {:ok, requested} <- normalize_namespace(namespace) do
            if requested == configured,
              do: {:ok, configured},
              else: {:error, {:namespace_mismatch, configured, requested}}
          end
      end
    end
  end

  @doc "Resolves a namespace and raises when none was configured."
  @spec namespace!(keyword()) :: namespace()
  def namespace!(opts \\ []) do
    case fetch_namespace(opts) do
      {:ok, namespace} -> namespace

      {:error, :namespace_required} ->
        raise ArgumentError,
              "SpectreMnemonic requires config :spectre_mnemonic, namespace: \"stable-name\""

      {:error, {:namespace_mismatch, configured, requested}} ->
        raise ArgumentError,
              "namespace #{inspect(requested)} does not match configured namespace #{inspect(configured)}"
    end
  end

  @doc "Adds the resolved namespace to an option list."
  @spec put_namespace(keyword()) :: {:ok, keyword()} | {:error, term()}
  def put_namespace(opts) do
    with {:ok, namespace} <- fetch_namespace(opts) do
      {:ok, Keyword.put(opts, :namespace, namespace)}
    end
  end

  @doc "Extracts a namespace from a record or its metadata."
  @spec namespace(term()) :: namespace() | nil
  def namespace(%{namespace: namespace}) when is_binary(namespace), do: namespace

  def namespace(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :namespace) || Map.get(metadata, "namespace")
  end

  def namespace(_record), do: nil

  @doc "Stores authoritative namespace and scope in metadata."
  @spec put_context(map(), keyword()) :: map()
  def put_context(metadata, opts) when is_map(metadata) do
    metadata
    |> Map.put(:namespace, namespace!(opts))
    |> Map.put(:scope, Keyword.get(opts, :scope))
  end

  @doc "Creates a prefixed UUIDv7 id."
  @spec generate(binary(), keyword()) :: binary()
  def generate(prefix, opts \\ []) when is_binary(prefix) and prefix != "" do
    _namespace = namespace!(opts)
    "#{prefix}_#{uuid7()}"
  end

  @doc "Derives a stable prefixed id from a UUIDv7 source id."
  @spec derived(binary(), binary(), keyword()) :: binary()
  def derived(prefix, source_id, opts \\ [])
      when is_binary(prefix) and prefix != "" and is_binary(source_id) do
    _namespace = namespace!(opts)

    case Regex.run(
           ~r/([0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i,
           source_id,
           capture: :all_but_first
         ) do
      [uuid] -> "#{prefix}_#{String.downcase(uuid)}"
      nil -> generate(prefix, opts)
    end
  end

  @doc "Creates an RFC 9562 UUIDv7 using a millisecond timestamp and crypto randomness."
  @spec uuid7() :: binary()
  def uuid7 do
    timestamp = System.system_time(:millisecond)
    <<random_a::12, random_b::62, _discard::6>> = :crypto.strong_rand_bytes(10)

    <<part1::32, part2::16, part3::16, part4::16, part5::48>> =
      <<timestamp::48, 0x7::4, random_a::12, 0b10::2, random_b::62>>

    Enum.join(
      [hex(part1, 8), hex(part2, 4), hex(part3, 4), hex(part4, 4), hex(part5, 12)],
      "-"
    )
  end

  @spec normalize_namespace(term()) :: {:ok, namespace()} | {:error, :namespace_required}
  defp normalize_namespace(namespace) when is_binary(namespace) do
    case String.trim(namespace) do
      "" -> {:error, :namespace_required}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_namespace(_namespace), do: {:error, :namespace_required}

  @spec hex(non_neg_integer(), pos_integer()) :: binary()
  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
