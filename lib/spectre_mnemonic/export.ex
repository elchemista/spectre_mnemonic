defmodule SpectreMnemonic.Export do
  @moduledoc """
  Verified, canonical JSON `.mnemonic` export reader.

  Export files contain exactly one memory partition. Reader verification checks
  framing, CRC32, format version, section counts, SHA-256 content digest, and
  every record's namespace/scope digest before returning data.
  """

  alias SpectreMnemonic.Export.Reader
  alias SpectreMnemonic.Export.Writer

  defstruct manifest: %{},
            nodes: [],
            edges: [],
            clusters: [],
            models: [],
            knowledge: [],
            governance: [],
            trailer: %{}

  @type t :: %__MODULE__{
          manifest: map(),
          nodes: [map()],
          edges: [map()],
          clusters: [map()],
          models: [map()],
          knowledge: [map()],
          governance: [map()],
          trailer: map()
        }

  @doc false
  @spec write(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(path, opts), do: Writer.write(path, opts)

  @doc "Fully decodes and verifies one `.mnemonic` file."
  @spec read(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def read(path, opts \\ []) do
    with {:ok, frames} <- Reader.read(path, opts) do
      sections = Enum.reduce(frames, %{}, &merge_frame/2)

      {:ok,
       %__MODULE__{
         manifest: Map.get(sections, "manifest", %{}),
         nodes: Map.get(sections, "nodes", []),
         edges: Map.get(sections, "edges", []),
         clusters: Map.get(sections, "clusters", []),
         models: Map.get(sections, "models", []),
         knowledge: Map.get(sections, "knowledge", []),
         governance: Map.get(sections, "governance", []),
         trailer: Map.get(sections, "trailer", %{})
       }}
    end
  end

  @doc "Returns a verified enumerable of section frames."
  @spec stream(Path.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(path, opts \\ []) do
    Reader.stream(path, opts)
  end

  @spec merge_frame(map(), map()) :: map()
  defp merge_frame(%{"section" => section, "data" => data}, sections)
       when section in ~w(nodes edges clusters models knowledge governance) do
    Map.update(sections, section, data, &(&1 ++ data))
  end

  defp merge_frame(%{"section" => section, "data" => data}, sections),
    do: Map.put(sections, section, data)
end
