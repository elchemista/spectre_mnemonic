defmodule SpectreMnemonic.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "Spectre uses Hex normally and the explicit compatibility path when requested" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    case System.get_env("SPECTRE_PATH") do
      path when is_binary(path) and path != "" ->
        assert {:spectre, opts} = dependency
        assert opts[:path] == Path.expand(path, File.cwd!())
        assert opts[:override]
        assert opts[:optional]

      _unset ->
        assert {:spectre, "~> 0.3.3", opts} = dependency
        assert opts[:optional]
    end

    refute Keyword.has_key?(config, :package)
  end

  test "Vettore uses Hex 0.3.5 or an explicit local path" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :vettore))

    case System.get_env("VETTORE_PATH") do
      path when is_binary(path) and path != "" ->
        assert {:vettore, opts} = dependency
        assert opts[:path] == Path.expand(path, File.cwd!())
        assert opts[:override]

      _unset ->
        assert {:vettore, "~> 0.3.5"} = dependency
    end
  end

  test "JSON and native tokenization are optional and Nx is not a direct dependency" do
    dependencies = Mix.Project.config() |> Keyword.fetch!(:deps)

    assert {:jason, "~> 1.4", opts} =
             Enum.find(dependencies, &(elem(&1, 0) == :jason))

    assert opts[:optional]

    assert {:tokenizers, "~> 0.5", tokenizer_opts} =
             Enum.find(dependencies, &(elem(&1, 0) == :tokenizers))

    assert tokenizer_opts[:optional]
    refute Enum.any?(dependencies, &(elem(&1, 0) == :nx))
  end
end
