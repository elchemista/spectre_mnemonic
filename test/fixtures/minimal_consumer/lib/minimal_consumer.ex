defmodule SpectreMnemonicMinimalConsumer do
  @moduledoc false

  @tokenizer_module Module.concat(["Tokenizers", "Tokenizer"])
  @nx_module Module.concat(["Nx"])
  @spectre_module Module.concat(["Spectre"])

  def smoke! do
    unless Application.get_env(:spectre_mnemonic, :json_library) == JSON do
      raise "built-in JSON configuration was not loaded"
    end

    if Code.ensure_loaded?(@tokenizer_module), do: raise("Tokenizers must remain optional")
    if Code.ensure_loaded?(@nx_module), do: raise("Nx must remain optional")
    if Code.ensure_loaded?(@spectre_module), do: raise("Spectre must remain optional")

    Enum.each(
      [
        SpectreMnemonic,
        SpectreMnemonic.Active.Focus,
        SpectreMnemonic.Engine,
        SpectreMnemonic.Persistence.Manager,
        SpectreMnemonic.Recall.Engine
      ],
      fn module ->
        unless Code.ensure_loaded?(module),
          do: raise("missing standalone core module #{inspect(module)}")
      end
    )

    suffix = System.unique_integer([:positive, :monotonic])
    scope = {:subject, "minimal"}
    path = Path.join(System.tmp_dir!(), "spectre-mnemonic-minimal-consumer-#{suffix}.mnemonic")
    root = Path.join(System.tmp_dir!(), "spectre-mnemonic-minimal-consumer-#{suffix}")

    {:error, :mnemonic_engine_required} = SpectreMnemonic.recall("missing engine")

    {:ok, engine} =
      SpectreMnemonic.Engine.start_link(
        storage_id: "minimal-consumer-#{suffix}",
        namespace: "minimal_consumer",
        data_root: root
      )

    try do
      {:ok, _memory} =
        SpectreMnemonic.remember("minimal dependency smoke test",
          engine: engine,
          scope: scope
        )

      {:ok, _report} =
        SpectreMnemonic.export(path, engine: engine, scope: scope, mode: :full)

      {:ok, decoded} = SpectreMnemonic.Export.read(path)

      true = decoded.nodes != []
      :ok
    after
      Supervisor.stop(engine)
      File.rm(path)
      File.rm_rf(root)
    end
  end
end
