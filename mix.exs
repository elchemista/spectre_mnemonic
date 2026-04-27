defmodule SpectreMnemonic.MixProject do
  @moduledoc false

  use Mix.Project

  @spec project :: keyword()
  def project do
    [
      app: :spectre_mnemonic,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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

  # Dependencies stay intentionally small for V1. Nx is listed by the plan for
  # vector math; this first pass still works when no embedding adapter exists.
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
