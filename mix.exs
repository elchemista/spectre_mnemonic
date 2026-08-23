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
      deps: deps(),
      description: description(),
      dialyzer: [plt_add_apps: [:mix]],
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        extras: ["README.md", "docs/PUBLIC_API.md", "CHANGELOG.md", "LICENSE"]
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

  # Nx powers local vector math and Model2Vec pooling. Axon/Bumblebee belong in
  # higher-level embedding adapters that run neural model forward passes.
  @spec deps :: [{atom(), binary()} | {atom(), binary(), keyword()}]
  defp deps do
    [
      spectre_dep(),
      {:jason, "~> 1.4"},
      {:tokenizers, "~> 0.5"},
      {:nx, "~> 0.11"},
      {:hnswlib, "~> 0.1", optional: true},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
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
