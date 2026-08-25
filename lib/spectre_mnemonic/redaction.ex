defmodule SpectreMnemonic.Redaction do
  @moduledoc false

  import Kernel, except: [apply: 2]

  @phone_regex ~r/(?<![\w@])(?:\+\d{1,3}[\s.-]?)?(?:\d[\s.-]?){6,}\d(?![\w@])/u
  @phone_placeholder "[redacted phone]"

  @type sensitive_number_mode :: :classify | :raw | :skip

  @spec apply(binary(), keyword() | sensitive_number_mode()) :: binary()
  def apply(text, opts) when is_binary(text) and is_list(opts),
    do: apply(text, Keyword.get(opts, :sensitive_numbers, :classify))

  def apply(text, :raw) when is_binary(text), do: text

  def apply(text, mode) when is_binary(text) and mode in [:classify, :skip] do
    Regex.replace(@phone_regex, text, fn candidate ->
      if date_like?(candidate), do: candidate, else: @phone_placeholder
    end)
  end

  @spec apply_term(term(), keyword() | sensitive_number_mode()) :: term()
  def apply_term(value, opts) when is_list(opts),
    do: apply_term(value, Keyword.get(opts, :sensitive_numbers, :classify))

  def apply_term(value, :raw), do: value
  def apply_term(value, mode) when is_binary(value), do: apply(value, mode)
  def apply_term(%_struct{} = value, _mode), do: value

  def apply_term(value, mode) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, apply_term(nested, mode)} end)
  end

  def apply_term(value, mode) when is_list(value),
    do: Enum.map(value, &apply_term(&1, mode))

  def apply_term(value, mode) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&apply_term(&1, mode))
    |> List.to_tuple()
  end

  def apply_term(value, _mode), do: value

  @spec phone_values(binary()) :: [binary()]
  def phone_values(text) when is_binary(text) do
    @phone_regex
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reject(&date_like?/1)
  end

  @spec placeholder() :: binary()
  def placeholder, do: @phone_placeholder

  @spec date_like?(binary()) :: boolean()
  defp date_like?(candidate), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/u, candidate)
end
