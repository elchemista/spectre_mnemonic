defmodule SpectreMnemonic.MixProject do
  @moduledoc false

  use Mix.Project

  @version "0.2.0"
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

  @spec package :: keyword()
  defp package do
    [
      name: "spectre_mnemonic",
      maintainers: ["elchemista"],
      files: ~w(
        lib
        docs
        mix.exs
        README.md
        CHANGELOG.md
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
    case {System.get_env("SPECTRE_HEX_BUILD"), System.get_env("SPECTRE_PATH")} do
      {hex_build, _path} when hex_build in ["1", "true"] ->
        {:spectre, "~> 0.2.0"}

      {_hex_build, path} when is_binary(path) and path != "" ->
        {:spectre, "~> 0.2.0", path: Path.expand(path)}

      _other ->
        {:spectre, "~> 0.2.0", github: "elchemista/spectre", branch: "main"}
    end
  end
end
