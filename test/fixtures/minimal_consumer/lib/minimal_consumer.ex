defmodule SpectreMnemonicMinimalConsumer do
  @moduledoc false

  @tokenizer_module Module.concat(["Tokenizers", "Tokenizer"])
  @nx_module Module.concat(["Nx"])

  def smoke! do
    unless Application.get_env(:spectre_mnemonic, :json_library) == JSON do
      raise "built-in JSON configuration was not loaded"
    end

    if Code.ensure_loaded?(@tokenizer_module), do: raise("Tokenizers must remain optional")
    if Code.ensure_loaded?(@nx_module), do: raise("Nx must remain optional")

    scope = {:subject, "minimal"}
    path = Path.join(System.tmp_dir!(), "spectre-mnemonic-minimal-consumer.mnemonic")

    try do
      {:ok, _memory} =
        SpectreMnemonic.remember("minimal dependency smoke test",
          scope: scope
        )

      {:ok, _report} = SpectreMnemonic.export(path, scope: scope, mode: :full)
      {:ok, decoded} = SpectreMnemonic.Export.read(path)

      true = decoded.nodes != []
      :ok
    after
      File.rm(path)
    end
  end
end
