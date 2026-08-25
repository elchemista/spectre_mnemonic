defmodule SpectreMnemonic.Integration.Vettore035Test do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Embedding.Vector
  alias SpectreMnemonic.Recall.Index

  test "uses Vettore 0.3.5 vector kernels with portable GPU fallback" do
    assert to_string(Application.spec(:vettore, :vsn)) == "0.3.5"
    assert Code.ensure_loaded?(Vettore.Vector)
    assert function_exported?(Vettore.Vector, :mean_pool_f32, 4)
    assert function_exported?(Vettore.Vector, :to_nx, 2)

    assert {:ok, normalized} =
             Vettore.Vector.normalize([3.0, 4.0], :l2,
               as: :list,
               gpu: :auto,
               gpu_min_size: 1,
               gpu_fallback: :cpu
             )

    assert_in_delta Enum.at(normalized, 0), 0.6, 1.0e-6
    assert_in_delta Enum.at(normalized, 1), 0.8, 1.0e-6
    assert %{gpu: _mode, fallback: _fallback, min_size: _minimum} = Vettore.Compute.info()
  end

  test "passes GPU policies to a partition-local Flat index" do
    scope = {:subject, "gpu-flat-policy"}

    Application.put_env(:spectre_mnemonic, :embedding,
      index: [
        backend: :vettore,
        vettore_index: :flat,
        strategy: :exact,
        vettore_index_options: [gpu: :auto, gpu_min_size: 1, gpu_fallback: :cpu]
      ]
    )

    assert {:ok, %{moment: moment}} =
             SpectreMnemonic.signal("GPU-indexed vector",
               scope: scope,
               embedding: [1.0, 0.0]
             )

    state = :sys.get_state(Index)
    indexed = Map.fetch!(state.vettore, {"spectre_mnemonic_test", scope})

    assert indexed.collection.index == :flat
    assert indexed.collection.index_options == [gpu: :auto, gpu_min_size: 1, gpu_fallback: :cpu]

    cue = %{vector: Vector.normalize_to_f32_binary([1.0, 0.0]), binary_signature: <<1>>}
    assert {:ok, [%{id: id} | _rest]} = Index.query(cue, scope: scope, overfetch: 1)
    assert id == moment.id
  end
end
