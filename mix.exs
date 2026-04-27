defmodule SpectreMnemonic.MixProject do
  use Mix.Project

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
  def application do
    [
      mod: {SpectreMnemonic.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Dependencies stay intentionally small for V1. Nx is listed by the plan for
  # vector math; this first pass still works when no embedding adapter exists.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:tokenizers, "~> 0.5"},
      {:nx, "~> 0.11"},
      {:hnswlib, "~> 0.1", optional: true}
    ]
  end
end
