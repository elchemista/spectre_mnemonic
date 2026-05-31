defmodule SpectreMnemonic.Observations do
  @moduledoc """
  Evidence-grounded observations built from existing moments and governance facts.

  Observations are derived claims such as "Project X owner is Ana". They are not
  raw memories. Each observation keeps source ids, supporting and weakening
  evidence, confidence, proof counts, contradiction counts, temporal metadata,
  and lifecycle state.
  """

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Embedding.Service
  alias SpectreMnemonic.Governance
  alias SpectreMnemonic.Memory.Observation
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Temporal
  alias SpectreMnemonic.Persistence.Manager

  @observation_table :mnemonic_observations

  @doc """
  Consolidates observations from active and durable moments.

  The consolidator reads visible moments, extracts fact claims through
  `SpectreMnemonic.Governance.fact_claim/1`, extracts deterministic preference,
  decision, pattern, and project-state observations, groups matching claims, and
  writes observation records. Pass `include_durable?: false` to derive
  observations only from active memory.

  ## Example

      iex> SpectreMnemonic.Observations.consolidate(include_durable?: false)
      {:ok, [%SpectreMnemonic.Memory.Observation{} | _]}
  """
  @spec consolidate(keyword()) :: {:ok, [Observation.t()]} | {:error, term()}
  def consolidate(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    observations =
      opts
      |> source_moments()
      |> Enum.filter(&visible?(&1, opts))
      |> Enum.flat_map(&observation_entries(&1, opts))
      |> build_observations(now, opts)

    Enum.each(observations, &store_observation(&1, opts))
    {:ok, observations}
  end

  @doc """
  Searches active observations and durable observation records.

  Results are filtered by scope and temporal options, then ranked by keyword
  overlap for active observations and merged with durable search results.

  ## Example

      iex> SpectreMnemonic.Observations.search("project owner", scope: {:agent, "planner"})
      {:ok, _observations}
  """
  @spec search(term(), keyword()) :: {:ok, [Observation.t() | map()]}
  def search(cue, opts \\ []) do
    active =
      @observation_table
      |> safe_tab2list()
      |> Enum.map(fn {_id, observation} -> observation end)
      |> Enum.filter(&visible?(&1, opts))
      |> score_observations(cue)

    durable = durable_observations(cue, opts)

    limit = Keyword.get(opts, :limit, 10)
    {:ok, (active ++ durable) |> Enum.uniq_by(&Map.get(&1, :id)) |> Enum.take(limit)}
  end

  @doc """
  Adds a verification event for an observation and returns the updated observation.

  Use `relation: :supports` to strengthen an observation, or `:weakens` /
  `:contradicts` to record negative evidence. The function updates confidence,
  proof counts, contradiction counts, trend, and state in one place.

  ## Example

      iex> SpectreMnemonic.Observations.verify(observation, relation: :contradicts, source_id: "mom_2")
      {:ok, %SpectreMnemonic.Memory.Observation{}}
  """
  @spec verify(binary() | Observation.t(), keyword()) :: {:ok, Observation.t()} | {:error, term()}
  def verify(observation_or_id, opts \\ [])

  def verify(%Observation{} = observation, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    relation = Keyword.get(opts, :relation, :supports)
    source_id = Keyword.get(opts, :source_id)
    confidence_delta = Keyword.get(opts, :confidence_delta, 0.08)

    evidence =
      [%{source_id: source_id, relation: relation, observed_at: now}]
      |> Enum.reject(&is_nil(&1.source_id))

    # Verification is append-like at the observation level: keep prior evidence
    # and add the new event, then derive the public counters and state from the
    # resulting evidence set.
    proof_count = observation.proof_count + if(relation == :supports, do: 1, else: 0)

    contradiction_count =
      observation.contradiction_count + if(relation in [:weakens, :contradicts], do: 1, else: 0)

    observation = %{
      observation
      | evidence: observation.evidence ++ evidence,
        source_ids: Enum.uniq(observation.source_ids ++ Enum.map(evidence, & &1.source_id)),
        proof_count: proof_count,
        contradiction_count: contradiction_count,
        confidence: verified_confidence(observation.confidence, relation, confidence_delta),
        last_verified_at: now,
        trend: verified_trend(relation),
        state: state(proof_count, contradiction_count)
    }

    store_observation(observation, opts)
    {:ok, observation}
  end

  def verify(id, opts) when is_binary(id) do
    case :ets.lookup(@observation_table, id) do
      [{^id, observation}] -> verify(observation, opts)
      [] -> {:error, :not_found}
    end
  end

  @spec durable_observations(term(), keyword()) :: [Observation.t() | map()]
  defp durable_observations(cue, opts) do
    case safe_manager_search(cue, opts) do
      {:ok, results} ->
        results
        |> Enum.filter(&(Map.get(&1, :family) == :observations))
        |> Enum.map(&Map.get(&1, :record, &1))
        |> Enum.filter(&visible?(&1, opts))

      {:error, _reason} ->
        []
    end
  end

  @spec store_observation(Observation.t(), keyword()) :: :ok
  defp store_observation(%Observation{} = observation, opts) do
    :ets.insert(@observation_table, {observation.id, observation})

    if Keyword.get(opts, :persist?, true) do
      Manager.append(:observations, observation, Keyword.put(opts, :record_id, observation.id))
      Governance.append_state(observation.id, observation.state, :observation_consolidated, opts)
    end

    :ok
  end

  @spec source_moments(keyword()) :: [map()]
  defp source_moments(opts) do
    active = Focus.moments()

    durable =
      if Keyword.get(opts, :include_durable?, true) do
        case safe_manager_replay(opts) do
          {:ok, records} ->
            records
            |> Enum.filter(&(&1.family == :moments))
            |> Enum.map(& &1.payload)

          {:error, _reason} ->
            []
        end
      else
        []
      end

    (active ++ durable)
    |> Enum.uniq_by(&Map.get(&1, :id))
  end

  @spec safe_manager_search(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp safe_manager_search(cue, opts) do
    Manager.search(cue, opts)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec safe_manager_replay(keyword()) :: {:ok, [map()]} | {:error, term()}
  defp safe_manager_replay(opts) do
    Manager.replay(opts)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec observation_entries(map(), keyword()) :: [map()]
  defp observation_entries(moment, _opts) do
    fact_entries(moment) ++ typed_entries(moment)
  end

  @spec fact_entries(map()) :: [map()]
  defp fact_entries(moment) do
    case Governance.fact_claim(moment) do
      nil ->
        []

      fact ->
        [
          %{
            type: :fact,
            moment: moment,
            fact: fact,
            scope: Scope.scope(moment),
            temporal: Temporal.temporal_map(moment)
          }
        ]
    end
  end

  @spec typed_entries(map()) :: [map()]
  defp typed_entries(%{text: text} = moment) when is_binary(text) do
    text
    |> semantic_claims()
    |> Enum.map(fn claim ->
      statement = normalize_statement(claim.statement)

      %{
        type: claim.type,
        key: "#{claim.type}:#{statement}",
        statement: statement,
        confidence: claim.confidence,
        moment: moment,
        scope: Scope.scope(moment),
        temporal: Temporal.temporal_map(moment)
      }
    end)
    |> Enum.reject(&(&1.statement == ""))
  end

  defp typed_entries(_moment), do: []

  @spec visible?(map(), keyword()) :: boolean()
  defp visible?(memory, opts), do: Scope.match?(memory, opts) and Temporal.match?(memory, opts)

  @spec build_observations([map()], DateTime.t(), keyword()) :: [Observation.t()]
  defp build_observations(entries, now, opts) do
    {facts, typed} = Enum.split_with(entries, &(&1.type == :fact))

    build_fact_observations(facts, now, opts) ++
      build_typed_observations(typed, now, opts)
  end

  @spec build_fact_observations([map()], DateTime.t(), keyword()) :: [Observation.t()]
  defp build_fact_observations(entries, now, opts) do
    entries
    |> Enum.group_by(fn entry -> {entry.scope, entry.fact.key} end)
    |> Enum.flat_map(fn {{scope, fact_key}, key_entries} ->
      key_entries
      |> Enum.group_by(& &1.fact.value)
      |> Enum.map(fn {value, supports} ->
        weakens = Enum.reject(key_entries, &(&1.fact.value == value))
        fact = hd(supports).fact
        build_fact_observation(scope, fact_key, fact, supports, weakens, now, opts)
      end)
    end)
  end

  @spec build_fact_observation(term(), binary(), map(), [map()], [map()], DateTime.t(), keyword()) ::
          Observation.t()
  defp build_fact_observation(scope, fact_key, fact, supports, weakens, now, opts) do
    statement = "#{fact.subject} #{fact.attribute} is #{fact.value}"
    source_ids = supports |> Enum.map(& &1.moment.id) |> Enum.uniq()
    contradiction_count = length(weakens)
    proof_count = length(supports)
    confidence = confidence(proof_count, contradiction_count, fact.confidence)
    trend = trend(proof_count, contradiction_count)
    state = state(proof_count, contradiction_count)
    embedding = Service.embed(statement, opts)
    temporal = observation_temporal(supports, now)
    id = Keyword.get(opts, :id) || stable_observation_id(scope, fact_key, fact.value)

    %Observation{
      id: id,
      statement: statement,
      scope: scope,
      tags: Keyword.get(opts, :tags, []),
      source_ids: source_ids,
      evidence:
        evidence(supports, :supports) ++
          evidence(
            weakens,
            if(contradiction_count > proof_count, do: :contradicts, else: :weakens)
          ),
      proof_count: proof_count,
      contradiction_count: contradiction_count,
      confidence: confidence,
      trend: trend,
      state: state,
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      keywords: keywords(statement),
      entities: entities(statement),
      occurred_at: temporal.occurred_at,
      observed_at: temporal.observed_at,
      last_verified_at: temporal.last_verified_at,
      valid_from: temporal.valid_from,
      valid_until: temporal.valid_until,
      metadata:
        %{
          observation_type: :fact,
          fact_key: fact_key,
          fact_subject: fact.subject,
          fact_attribute: fact.attribute,
          fact_value: fact.value,
          provenance: %{
            source_ids: source_ids,
            provider: :observations,
            confidence: confidence,
            observed_at: temporal.observed_at || now,
            last_verified_at: temporal.last_verified_at || now
          }
        }
        |> Map.put(:scope, scope)
        |> Temporal.put_metadata(temporal),
      inserted_at: now
    }
  end

  @spec build_typed_observations([map()], DateTime.t(), keyword()) :: [Observation.t()]
  defp build_typed_observations(entries, now, opts) do
    entries
    |> Enum.group_by(fn entry -> {entry.scope, entry.type, entry.key} end)
    |> Enum.map(fn {{scope, type, key}, supports} ->
      build_typed_observation(scope, type, key, supports, now, opts)
    end)
  end

  @spec build_typed_observation(term(), atom(), binary(), [map()], DateTime.t(), keyword()) ::
          Observation.t()
  defp build_typed_observation(scope, type, key, supports, now, opts) do
    statement = hd(supports).statement
    source_ids = supports |> Enum.map(& &1.moment.id) |> Enum.uniq()
    proof_count = length(supports)
    base_confidence = supports |> Enum.map(& &1.confidence) |> Enum.max(fn -> 0.65 end)
    confidence = confidence(proof_count, 0, base_confidence)
    trend = trend(proof_count, 0)
    state = state(proof_count, 0)
    embedding = Service.embed(statement, opts)
    temporal = observation_temporal(supports, now)
    id = Keyword.get(opts, :id) || stable_observation_id(scope, key, statement)

    %Observation{
      id: id,
      statement: statement,
      scope: scope,
      tags: Keyword.get(opts, :tags, []),
      source_ids: source_ids,
      evidence: evidence(supports, :supports),
      proof_count: proof_count,
      contradiction_count: 0,
      confidence: confidence,
      trend: trend,
      state: state,
      vector: embedding.vector,
      binary_signature: Map.get(embedding, :binary_signature),
      embedding: embedding,
      keywords: keywords(statement),
      entities: entities(statement),
      occurred_at: temporal.occurred_at,
      observed_at: temporal.observed_at,
      last_verified_at: temporal.last_verified_at,
      valid_from: temporal.valid_from,
      valid_until: temporal.valid_until,
      metadata:
        %{
          observation_type: type,
          observation_key: key,
          provenance: %{
            source_ids: source_ids,
            provider: :observations,
            confidence: confidence,
            observed_at: temporal.observed_at || now,
            last_verified_at: temporal.last_verified_at || now
          }
        }
        |> Map.put(:scope, scope)
        |> Temporal.put_metadata(temporal),
      inserted_at: now
    }
  end

  @spec observation_temporal([map()], DateTime.t()) :: map()
  defp observation_temporal(entries, now) do
    temporals = Enum.map(entries, & &1.temporal)

    %{
      occurred_at: earliest(temporals, :occurred_at),
      observed_at: latest(temporals, :observed_at) || now,
      last_verified_at: latest(temporals, :last_verified_at) || now,
      valid_from: earliest(temporals, :valid_from),
      valid_until: latest(temporals, :valid_until)
    }
  end

  @spec evidence([map()], atom()) :: [map()]
  defp evidence(entries, relation) do
    Enum.map(entries, fn entry ->
      %{
        source_id: entry.moment.id,
        relation: relation,
        confidence: Map.get(entry, :confidence) || entry.fact.confidence,
        observed_at: Map.get(entry.temporal, :observed_at)
      }
    end)
  end

  @spec semantic_claims(binary()) :: [map()]
  defp semantic_claims(text) do
    [
      semantic_claim(text, :preference, ~r/\b(?:the\s+)?user\s+prefers?\s+(?<body>[^.;\n]+)/iu,
        prefix: "user prefers "
      ),
      semantic_claim(text, :preference, ~r/\bprefer\s+(?<body>[^.;\n]+)/iu, prefix: "prefer "),
      semantic_claim(text, :preference, ~r/\bavoid\s+(?<body>[^.;\n]+)/iu, prefix: "avoid "),
      semantic_claim(text, :decision, ~r/\bdecided\s+to\s+(?<body>[^.;\n]+)/iu,
        prefix: "decided to "
      ),
      semantic_claim(text, :decision, ~r/\bdecision\s+(?:is|was)\s+to\s+(?<body>[^.;\n]+)/iu,
        prefix: "decision is to "
      ),
      semantic_claim(text, :decision, ~r/\bwill\s+use\s+(?<body>[^.;\n]+)/iu,
        prefix: "will use "
      ),
      semantic_claim(
        text,
        :pattern,
        ~r/\b(?:this\s+agent|agent|system|it)\s+often\s+(?<body>[^.;\n]+)/iu,
        prefix: "agent often "
      ),
      semantic_claim(
        text,
        :pattern,
        ~r/\b(?:this\s+agent|agent|system|it)\s+usually\s+(?<body>[^.;\n]+)/iu,
        prefix: "agent usually "
      ),
      semantic_claim(
        text,
        :pattern,
        ~r/\b(?:this\s+agent|agent|system|it)\s+keeps\s+(?<body>[^.;\n]+)/iu,
        prefix: "agent keeps "
      ),
      semantic_claim(text, :pattern, ~r/\bkeeps\s+failing\s+because\s+(?<body>[^.;\n]+)/iu,
        prefix: "keeps failing because "
      ),
      semantic_claim(text, :project_state, ~r/\bproject\s+direction\s+is\s+(?<body>[^.;\n]+)/iu,
        prefix: "project direction is "
      ),
      semantic_claim(
        text,
        :project_state,
        ~r/\bmoving\s+(?<body>(?:toward|towards|away\s+from)\s+[^.;\n]+)/iu,
        prefix: "moving "
      ),
      semantic_claim(text, :project_state, ~r/\bblocked\s+by\s+(?<body>[^.;\n]+)/iu,
        prefix: "blocked by "
      ),
      semantic_claim(
        text,
        :project_state,
        ~r/\bcurrent\s+status\s+(?:is|:)\s+(?<body>[^.;\n]+)/iu,
        prefix: "current status is "
      )
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn claim -> {claim.type, normalize_statement(claim.statement)} end)
    |> reject_subsumed_claims()
  end

  @spec reject_subsumed_claims([map()]) :: [map()]
  defp reject_subsumed_claims(claims) do
    Enum.reject(claims, fn claim ->
      statement = normalize_statement(claim.statement)

      Enum.any?(claims, fn other ->
        other.type == claim.type and
          normalize_statement(other.statement) != statement and
          String.contains?(normalize_statement(other.statement), statement)
      end)
    end)
  end

  @spec semantic_claim(binary(), atom(), Regex.t(), keyword()) :: [map()]
  defp semantic_claim(text, type, pattern, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    pattern
    |> Regex.scan(text, capture: :all_names)
    |> Enum.map(fn
      [body] ->
        %{
          type: type,
          statement: prefix <> String.trim(body),
          confidence: semantic_confidence(type)
        }

      _other ->
        nil
    end)
  end

  @spec semantic_confidence(atom()) :: float()
  defp semantic_confidence(:decision), do: 0.78
  defp semantic_confidence(:project_state), do: 0.74
  defp semantic_confidence(:preference), do: 0.72
  defp semantic_confidence(:pattern), do: 0.68
  defp semantic_confidence(_type), do: 0.65

  @spec normalize_statement(binary()) :: binary()
  defp normalize_statement(statement) do
    statement
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.replace(~r/\s+/u, " ")
    |> String.downcase()
  end

  @spec score_observations([Observation.t()], term()) :: [Observation.t()]
  defp score_observations(observations, cue) do
    query_terms = cue |> to_string() |> keywords() |> MapSet.new()
    query_entities = cue |> to_string() |> entities() |> normalized_set()

    observations
    |> Enum.map(fn observation ->
      keyword_overlap =
        observation.keywords
        |> MapSet.new()
        |> MapSet.intersection(query_terms)
        |> MapSet.size()

      entity_overlap =
        observation.entities
        |> normalized_set()
        |> MapSet.intersection(query_entities)
        |> MapSet.size()

      score =
        if keyword_overlap > 0 or entity_overlap > 0 do
          keyword_overlap * 2 + entity_overlap * 3 + observation.confidence
        else
          0
        end

      {score, observation}
    end)
    |> Enum.filter(fn {score, _observation} -> score > 0 end)
    |> Enum.sort_by(fn {score, observation} -> {-score, observation.id} end)
    |> Enum.map(fn {_score, observation} -> observation end)
  end

  @spec verified_confidence(float(), atom(), number()) :: float()
  defp verified_confidence(confidence, :supports, delta), do: clamp(confidence + delta)
  defp verified_confidence(confidence, :weakens, delta), do: clamp(confidence - delta)
  defp verified_confidence(confidence, :contradicts, delta), do: clamp(confidence - delta * 2)
  defp verified_confidence(confidence, _relation, _delta), do: clamp(confidence)

  @spec verified_trend(atom()) :: Observation.trend()
  defp verified_trend(:supports), do: :strengthening
  defp verified_trend(:weakens), do: :weakening
  defp verified_trend(:contradicts), do: :contradicted
  defp verified_trend(_relation), do: :stable

  @spec stable_observation_id(term(), binary(), binary()) :: binary()
  defp stable_observation_id(scope, fact_key, value) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({scope, fact_key, value}))
    "obs_#{Base.encode16(hash, case: :lower) |> binary_part(0, 24)}"
  end

  @spec confidence(non_neg_integer(), non_neg_integer(), number()) :: float()
  defp confidence(proof_count, contradiction_count, base) do
    (base + proof_count * 0.12 - contradiction_count * 0.1)
    |> clamp()
  end

  @spec clamp(number()) :: float()
  defp clamp(value), do: value |> max(0.0) |> min(0.98)

  @spec trend(non_neg_integer(), non_neg_integer()) :: Observation.trend()
  defp trend(proof_count, 0) when proof_count >= 2, do: :strengthening
  defp trend(_proof_count, contradiction_count) when contradiction_count > 0, do: :weakening
  defp trend(_proof_count, _contradiction_count), do: :stable

  @spec state(non_neg_integer(), non_neg_integer()) :: Governance.state()
  defp state(proof_count, contradiction_count) when contradiction_count > proof_count,
    do: :contradicted

  defp state(proof_count, _contradiction_count) when proof_count >= 2, do: :promoted
  defp state(_proof_count, _contradiction_count), do: :candidate

  @spec earliest([map()], atom()) :: DateTime.t() | nil
  defp earliest(temporals, field) do
    temporals
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  @spec latest([map()], atom()) :: DateTime.t() | nil
  defp latest(temporals, field) do
    temporals
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  @spec safe_tab2list(atom()) :: list()
  defp safe_tab2list(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  @spec keywords(binary()) :: [binary()]
  defp keywords(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  @spec entities(binary()) :: [binary()]
  defp entities(text) do
    Regex.scan(~r/\b\p{Lu}[\p{L}\p{N}_]+\b/u, text)
    |> List.flatten()
    |> Enum.uniq()
  end

  @spec normalized_set([term()]) :: MapSet.t(binary())
  defp normalized_set(values) do
    values
    |> Enum.map(&(to_string(&1) |> String.downcase()))
    |> MapSet.new()
  end
end
