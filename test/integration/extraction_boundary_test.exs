defmodule SpectreMnemonic.Integration.ExtractionBoundaryTest do
  use ExUnit.Case, async: true

  alias SpectreMnemonic.Intake.Extraction

  defmodule Adapter do
    def extract(_text, opts) do
      case Keyword.fetch!(opts, :adapter_result) do
        {:raise, message} -> raise message
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  test "unavailable or failed extraction adapters preserve deterministic entities" do
    for result <- [{:error, :offline}, {:raise, "offline"}, {:throw, :offline}] do
      assert {:ok, graph} =
               Extraction.extract("Alice visited Rome",
                 entity_extraction_adapter: Adapter,
                 adapter_result: result
               )

      assert Enum.any?(graph.entities, &(&1.name == "Alice"))
      assert Map.has_key?(graph.metadata, :error)
    end

    assert {:ok, %{metadata: %{error: :adapter_not_available}}} =
             Extraction.extract("Alice", entity_extraction_adapter: String)
  end

  test "model graph relations use a closed vocabulary and discard incomplete endpoints" do
    relations =
      ~w(actor acted_on happened_at has_value mentions_entity observed_in same_entity related_to)a

    entries =
      for relation <- relations, encoding <- [:atom, :string] do
        %{
          source: "alice",
          target: "#{relation}-#{encoding}",
          relation: if(encoding == :atom, do: relation, else: Atom.to_string(relation))
        }
      end

    entries =
      entries ++
        [
          %{source: "alice", target: "unknown", relation: 42},
          %{source: "alice", target: nil, relation: :actor}
        ]

    assert {:ok, graph} =
             Extraction.extract("",
               entity_extraction_adapter: Adapter,
               adapter_result: {:ok, %{relations: entries}}
             )

    assert length(graph.relations) == 17
    assert Enum.all?(graph.relations, &(&1.relation in relations))
    assert Enum.find(graph.relations, &(&1.target == "unknown")).relation == :related_to
  end
end
