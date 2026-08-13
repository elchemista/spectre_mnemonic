defmodule SpectreMnemonic.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "the project remains GitHub-only while Spectre is a direct Hex dependency" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    assert {:spectre, "~> 0.3.0"} = dependency
    refute Keyword.has_key?(config, :package)
  end
end
