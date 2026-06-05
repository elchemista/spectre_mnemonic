defmodule SpectreMnemonic.Result do
  @moduledoc false

  @spec collect_ok(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def collect_ok(enumerable, fun) do
    # Tiny helper, tiny contract: collect successes in order, stop at first
    # error. No suspense novel needed.
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
