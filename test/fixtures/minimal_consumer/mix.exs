defmodule SpectreMnemonicMinimalConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectre_mnemonic_minimal_consumer,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:spectre_mnemonic, path: "../../.."}
    ]
  end
end
