defmodule SpectreMnemonic.Integration.VectorHostNxCompatTest do
  use ExUnit.Case, async: false

  alias SpectreMnemonic.Embedding.Vector

  setup_all do
    nx = Module.concat(["Nx"])
    tensor = Module.concat(["Nx", "Tensor"])
    created_stub? = not Code.ensure_loaded?(nx)

    if created_stub? do
      create_nx_stub(nx, tensor)

      on_exit(fn ->
        :code.purge(nx)
        :code.delete(nx)
        :code.purge(tensor)
        :code.delete(tensor)
      end)
    end

    {:ok, nx: nx, tensor: tensor}
  end

  test "host-provided tensors cross the temporary compatibility facade", %{nx: nx, tensor: type} do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    tensor = apply(nx, :tensor, [[3.0, 4.0], [type: :f32]])

    assert tensor.__struct__ == type
    assert Vector.dimensions(tensor) == 2
    assert Vector.to_list(tensor) == [3.0, 4.0]
    assert Vector.to_f32_binary(tensor) == f32_binary([3.0, 4.0])
    assert_in_delta Vector.dot(tensor, [0.6, 0.8]), 5.0, 1.0e-6
    assert_in_delta Vector.cosine(tensor, [6.0, 8.0]), 1.0, 1.0e-6
  end

  test "tensor conversion and normalization delegate through Vettore", %{tensor: type} do
    tensor = Vector.to_tensor([3.0, 4.0])
    assert tensor.__struct__ == type

    normalized = Vector.normalize_tensor(tensor)
    assert normalized.__struct__ == type
    assert [x, y] = Vector.to_list(normalized)
    assert_in_delta x, 0.6, 1.0e-6
    assert_in_delta y, 0.8, 1.0e-6

    invalid = struct(type, data: [:bad], shape: {1})
    assert Vector.to_list(invalid) == []
    assert Vector.to_tensor(invalid) == {:error, :invalid_vector}
  end

  defp create_nx_stub(nx, tensor) do
    Module.create(
      tensor,
      quote do
        defstruct [:data, :shape]
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      nx,
      quote do
        def tensor(values, _opts) do
          struct(unquote(tensor), data: values, shape: {length(values)})
        end

        def to_flat_list(%{__struct__: unquote(tensor), data: values}), do: values
        def shape(%{__struct__: unquote(tensor), shape: shape}), do: shape

        def reshape(%{__struct__: unquote(tensor)} = value, shape) do
          %{value | shape: shape}
        end
      end,
      Macro.Env.location(__ENV__)
    )
  end

  defp f32_binary(values) do
    for value <- values, into: <<>>, do: <<value::float-little-32>>
  end
end
