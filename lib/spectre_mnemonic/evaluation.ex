defmodule SpectreMnemonic.Evaluation do
  @moduledoc """
  Small deterministic evaluation harness for memory quality and latency.
  """

  @doc "Runs a local evaluation scenario and returns aggregate metrics."
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    size = opts |> Keyword.get(:size, 100) |> max(1)
    started = System.monotonic_time()

    scenarios = Enum.map(1..size, &scenario/1)

    Enum.each(scenarios, fn scenario ->
      {:ok, _packet} =
        SpectreMnemonic.remember(scenario.text,
          stream: scenario.stream,
          task_id: scenario.task_id,
          kind: scenario.kind,
          persist?: true
        )
    end)

    recall_hits = Enum.count(scenarios, &recall_hit?/1)
    exact_hits = Enum.count(Enum.filter(scenarios, &(&1.kind == :fact)), &recall_hit?/1)

    latency_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    %{
      size: size,
      recall_accuracy: recall_hits / size,
      exact_fact_recall:
        if(Enum.any?(scenarios, &(&1.kind == :fact)),
          do: exact_hits / Enum.count(scenarios, &(&1.kind == :fact)),
          else: 0.0
        ),
      latency_ms: latency_ms
    }
  end

  @spec scenario(pos_integer()) :: map()
  defp scenario(index) do
    subject = "EvalSubject#{index}"

    if rem(index, 3) == 0 do
      %{
        kind: :fact,
        stream: :chat,
        task_id: nil,
        text: "#{subject} email is eval#{index}@example.com",
        cue: "#{subject} email",
        token: "eval#{index}@example.com"
      }
    else
      %{
        kind: :research,
        stream: :research,
        task_id: "eval-#{index}",
        text: "research #{subject} durable hybrid recall checkpoint #{index}",
        cue: "#{subject} hybrid recall",
        token: "checkpoint #{index}"
      }
    end
  end

  @spec recall_hit?(map()) :: boolean()
  defp recall_hit?(scenario) do
    {:ok, results} = SpectreMnemonic.search(scenario.cue, limit: 10)

    Enum.any?(results, fn result ->
      text = Map.get(result, :text) || record_text(Map.get(result, :record))
      String.contains?(text, scenario.token)
    end)
  end

  @spec record_text(term()) :: binary()
  defp record_text(%{text: text}) when is_binary(text), do: text
  defp record_text(_record), do: ""
end
