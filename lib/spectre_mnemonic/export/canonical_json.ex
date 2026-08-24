defmodule SpectreMnemonic.Export.CanonicalJSON do
  @moduledoc false

  @spec encode(term()) :: binary()
  def encode(value), do: encode_value(value)

  @spec encode_value(term()) :: binary()
  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Jason.encode!(value)
  defp encode_value(value) when is_binary(value), do: Jason.encode!(value)

  defp encode_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_value/1) <> "]"
  end

  defp encode_value(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
      |> Enum.map_join(",", fn {key, item} ->
        Jason.encode!(key) <> ":" <> encode_value(item)
      end)

    "{" <> entries <> "}"
  end
end
