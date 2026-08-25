defmodule SpectreMnemonic.MixProject do
  @moduledoc false

  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/elchemista/spectre_mnemonic"

  @spec project :: keyword()
  def project do
    [
      app: :spectre_mnemonic,
      name: "SpectreMnemonic",
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r|^test/fixtures/|],
      deps: deps(),
      description: description(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: [
          "README.md",
          "docs/GETTING_STARTED.md",
          "docs/MEMORY_GUIDE.md",
          "docs/RETRIEVAL_AND_KNOWLEDGE.md",
          "docs/PERSISTENCE_AND_OPERATIONS.md",
          "docs/PRIVACY_AND_GDPR.md",
          "docs/API_GUIDE.md",
          "docs/PUBLIC_API.md",
          "docs/MNEMONIC_FORMAT.md",
          "RELEASE.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        groups_for_extras: [
          Guides: [
            "docs/GETTING_STARTED.md",
            "docs/MEMORY_GUIDE.md",
            "docs/RETRIEVAL_AND_KNOWLEDGE.md",
            "docs/PERSISTENCE_AND_OPERATIONS.md",
            "docs/PRIVACY_AND_GDPR.md",
            "docs/API_GUIDE.md"
          ],
          Reference: ["docs/PUBLIC_API.md", "docs/MNEMONIC_FORMAT.md", "RELEASE.md"]
        ]
      ],
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  @spec application :: keyword()
  def application do
    [
      mod: {SpectreMnemonic.Application, []},
      extra_applications: [:logger, :crypto]
    ]
  end

  @spec description :: binary()
  defp description do
    "SpectreMnemonic: active and durable memory for Elixir applications"
  end

  @spec deps :: [{atom(), binary()} | {atom(), binary(), keyword()}]
  defp deps do
    [
      spectre_dep(),
      vettore_dep(),
      {:ex_fastembed,
       github: "elchemista/ex_fastembed",
       ref: "dddbf068d0202ba6d0a3788cc03992dc95203eaf",
       only: :test,
       runtime: false},
      {:jason, "~> 1.4", optional: true},
      {:tokenizers, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp vettore_dep do
    case System.get_env("VETTORE_PATH") do
      path when is_binary(path) and path != "" ->
        {:vettore, path: Path.expand(path, __DIR__), override: true}

      _unset ->
        {:vettore, "~> 0.3.5"}
    end
  end

  defp spectre_dep do
    case System.get_env("SPECTRE_PATH") do
      path when is_binary(path) and path != "" ->
        {:spectre, path: Path.expand(path, __DIR__), override: true}

      _unset ->
        {:spectre, "~> 0.3.3"}
    end
  end
end
