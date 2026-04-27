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
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"]
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
      extra_applications: [:logger]
    ]
  end

  @spec description :: binary()
  defp description do
    "SpectreMnemonic: active and durable memory for Elixir applications"
  end

  @spec package :: keyword()
  defp package do
    [
      name: "spectre_mnemonic",
      maintainers: ["elchemista"],
      files: ~w(
        lib
        mix.exs
        README.md
        LICENSE
      ),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  # Nx powers local vector math and Model2Vec pooling. Axon/Bumblebee belong in
  # higher-level embedding adapters that run neural model forward passes.
  @spec deps :: [{atom(), binary()} | {atom(), binary(), keyword()}]
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:tokenizers, "~> 0.5"},
      {:nx, "~> 0.11"},
      {:hnswlib, "~> 0.1", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
