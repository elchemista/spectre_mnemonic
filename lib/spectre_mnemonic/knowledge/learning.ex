defmodule SpectreMnemonic.Knowledge.Learning do
  @moduledoc """
  Normalizes agent-authored skills and stores them in compact knowledge.
  """

  alias SpectreMnemonic.Knowledge.{Base, SMEM}

  @type result :: %{event: SMEM.event(), seq: pos_integer()}

  @doc "Learns one skill by appending a `:skill` event to `knowledge.smem`."
  @spec learn(term(), keyword()) :: {:ok, result()} | {:error, term()}
  def learn(input, opts \\ []) do
    with {:ok, event} <- normalize(input, opts),
         {:ok, seq} <- Base.append(event, opts) do
      {:ok, %{event: event, seq: seq}}
    end
  end

  @spec normalize(term(), keyword()) :: {:ok, SMEM.event()} | {:error, term()}
  defp normalize(input, opts) when is_binary(input) do
    case String.trim(input) do
      "" ->
        {:error, :empty_skill}

      text ->
        text
        |> skill_from_text(opts)
        |> validate()
    end
  end

  defp normalize(input, opts) when is_list(input) do
    if Keyword.keyword?(input) do
      input |> Map.new() |> normalize(opts)
    else
      {:error, {:invalid_skill, :unsupported_input}}
    end
  end

  defp normalize(input, opts) when is_map(input) do
    input
    |> skill_from_map(opts)
    |> validate()
  end

  defp normalize(_input, _opts), do: {:error, {:invalid_skill, :unsupported_input}}

  @spec skill_from_text(binary(), keyword()) :: map()
  defp skill_from_text(text, opts) do
    name = opts |> Keyword.get(:name) |> text_value()
    lines = non_empty_lines(text)
    steps = bullet_steps(lines)

    %{
      type: :skill,
      name: name || first_line(lines),
      text: text,
      steps: if(steps == [], do: [text], else: steps),
      metadata: metadata(opts, %{})
    }
  end

  @spec skill_from_map(map(), keyword()) :: map()
  defp skill_from_map(input, opts) do
    text = text_value(value(input, :text))
    steps = map_steps(input, text)

    %{
      type: :skill,
      name: map_name(input, opts) || name_from_text(text),
      text: text || Enum.join(steps, "\n"),
      steps: steps,
      metadata: map_metadata(input, opts)
    }
  end

  @spec map_name(map(), keyword()) :: binary() | nil
  defp map_name(input, opts) do
    text_value(Keyword.get(opts, :name)) || text_value(value(input, :name))
  end

  @spec map_steps(map(), binary() | nil) :: [binary()]
  defp map_steps(input, text) do
    explicit_steps = input |> value(:steps, []) |> string_list()
    text_steps = text_steps(text)

    cond do
      explicit_steps != [] -> explicit_steps
      text_steps != [] -> text_steps
      is_binary(text) -> [text]
      true -> []
    end
  end

  @spec text_steps(binary() | nil) :: [binary()]
  defp text_steps(nil), do: []
  defp text_steps(text), do: text |> non_empty_lines() |> bullet_steps()

  @spec map_metadata(map(), keyword()) :: map()
  defp map_metadata(input, opts) do
    opts
    |> metadata(Map.new(value(input, :metadata, %{})))
    |> Map.merge(%{
      rules: string_list(value(input, :rules, [])),
      examples: string_list(value(input, :examples, []))
    })
  end

  @spec validate(map()) :: {:ok, SMEM.event()} | {:error, term()}
  defp validate(skill) do
    cond do
      blank?(Map.get(skill, :name)) ->
        {:error, {:invalid_skill, :missing_name}}

      reject_blank(Map.get(skill, :steps, [])) == [] and blank?(Map.get(skill, :text)) ->
        {:error, {:invalid_skill, :missing_content}}

      true ->
        {:ok,
         skill
         |> Map.update!(:steps, &reject_blank/1)
         |> SMEM.normalize_event()}
    end
  end

  @spec metadata(keyword(), map()) :: map()
  defp metadata(opts, metadata) do
    opts
    |> Keyword.get(:metadata, %{})
    |> Map.new()
    |> Map.merge(metadata)
    |> Map.put_new(:source, :learn)
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec string_list(term()) :: [binary()]
  defp string_list(values), do: values |> List.wrap() |> Enum.map(&to_string/1) |> reject_blank()

  @spec text_value(term()) :: binary() | nil
  defp text_value(nil), do: nil

  defp text_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text_value(value) when is_atom(value), do: value |> Atom.to_string() |> text_value()
  defp text_value(value), do: value |> to_string() |> text_value()

  @spec name_from_text(binary() | nil) :: binary() | nil
  defp name_from_text(nil), do: nil
  defp name_from_text(text), do: text |> non_empty_lines() |> first_line()

  @spec non_empty_lines(binary()) :: [binary()]
  defp non_empty_lines(text) do
    text
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> reject_blank()
  end

  @spec first_line([binary()]) :: binary() | nil
  defp first_line([]), do: nil
  defp first_line([line | _rest]), do: title_from_line(line)

  @spec title_from_line(binary()) :: binary()
  defp title_from_line(line) do
    line
    |> strip_marker()
    |> String.split(~r/(?<=[.!?])\s+/u, parts: 2)
    |> hd()
    |> String.trim()
  end

  @spec bullet_steps([binary()]) :: [binary()]
  defp bullet_steps(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(?:[-*+]|\d+[.)])\s+(.+)$/u, line, capture: :all_but_first) do
        [step] -> [String.trim(step)]
        _no_match -> []
      end
    end)
    |> reject_blank()
  end

  @spec strip_marker(binary()) :: binary()
  defp strip_marker(line) do
    Regex.replace(~r/^\s*(?:[-*+]|\d+[.)])\s+/u, line, "")
    |> String.trim()
  end

  @spec reject_blank([binary()]) :: [binary()]
  defp reject_blank(values), do: Enum.reject(values, &blank?/1)

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
