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

      _unset ->
        assert {:spectre, "~> 0.3.0"} = dependency
    end

    refute Keyword.has_key?(config, :package)
  end
end
