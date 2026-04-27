defmodule ParallelMemoryExample.Event do
  @moduledoc """
  Small example-side event model used by the demo script.
  """

  @enforce_keys [:type, :text]
  defstruct [
    :type,
    :text,
    :task_id,
    stream: :example,
    source: "inline",
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          type: atom(),
          text: binary(),
          task_id: binary() | nil,
          stream: atom(),
          source: binary(),
          metadata: map()
        }
end

defmodule ParallelMemoryExample.Parser do
  @moduledoc """
  Parses simple text fixtures into typed memory events.
  """

  alias ParallelMemoryExample.Event

  @spec from_file(Path.t()) :: [Event.t()]
  def from_file(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _line_no} -> skip?(line) end)
    |> Enum.map(fn {line, line_no} -> parse_line(path, line, line_no) end)
  end

  defp skip?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp parse_line(path, line, line_no) do
    {prefix, body} =
      case String.split(line, ":", parts: 2) do
        [prefix, body] -> {String.downcase(String.trim(prefix)), String.trim(body)}
        [body] -> {"note", String.trim(body)}
      end

    {type, stream} = event_shape(prefix, path)
    task_id = task_id(prefix, body, line_no)

    %Event{
      type: type,
      stream: stream,
      task_id: task_id,
      text: body,
      source: Path.basename(path),
      metadata: %{
        line: line_no,
        raw_prefix: prefix,
        example: :parallel_memory
      }
    }
  end

  defp event_shape("task", _path), do: {:task_execution, :task_execution}
  defp event_shape("todo", _path), do: {:task, :planning}
  defp event_shape("decision", _path), do: {:decision, :decisions}
  defp event_shape("event", _path), do: {:event, :events}
  defp event_shape("tool", _path), do: {:tool, :tool}
  defp event_shape("error", _path), do: {:error, :alerts}
  defp event_shape("research", _path), do: {:research, :research}
  defp event_shape("memory", _path), do: {:knowledge, :knowledge}
  defp event_shape("chat", _path), do: {:chat, :chat}
  defp event_shape("user", _path), do: {:chat, :chat}
  defp event_shape("assistant", _path), do: {:chat, :chat}
  defp event_shape("system", _path), do: {:system, :system}
  defp event_shape(_prefix, path), do: inferred_shape(path)

  defp inferred_shape(path) do
    case Path.basename(path) do
      "chat.txt" -> {:chat, :chat}
      "tasks.txt" -> {:task, :planning}
      _other -> {:note, :example}
    end
  end

  defp task_id(prefix, body, line_no) when prefix in ["task", "todo"] do
    body
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 40)
    |> case do
      "" -> "example-task-#{line_no}"
      slug -> "example-#{slug}"
    end
  end

  defp task_id(_prefix, _body, _line_no), do: nil
end
