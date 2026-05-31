defmodule SpectreMnemonic.Intake.MissionPolicy do
  @moduledoc """
  Opt-in mission-aware intake policy plug.

  Add this module to `remember/2` plugs when `:mission` should affect retention
  behavior instead of only being carried as metadata:

      SpectreMnemonic.remember(text,
        mission: :code_agent,
        plugs: [SpectreMnemonic.Intake.MissionPolicy]
      )

  The built-in `:code_agent` profile filters low-value conversational filler and
  enriches technical memory with priority and extraction hints. Other missions
  pass through unchanged unless a custom `:mission_policy` module is supplied.
  """

  alias SpectreMnemonic.Intake.Memory
  alias SpectreMnemonic.Intake.Packet

  @behaviour SpectreMnemonic.Intake.Plug

  @type keep_result :: true | false | {:rewrite, Memory.t()}

  @callback keep?(Memory.t(), term(), keyword()) :: keep_result()
  @callback priority(Memory.t(), term(), keyword()) :: float()
  @callback extraction_profile(term()) :: keyword()

  @optional_callbacks priority: 3, extraction_profile: 1

  @impl SpectreMnemonic.Intake.Plug
  def call(%Memory{} = memory, opts) do
    mission = memory.mission || Keyword.get(opts, :mission)

    case apply_policy(memory, mission, opts) do
      false ->
        {:ok,
         %Packet{
           warnings: [
             {:mission_policy_dropped, mission, :low_value_intake}
             | memory.warnings
           ],
           errors: memory.errors,
           persistence: %{mode: :mission_policy, durable?: false}
         }}

      {:rewrite, %Memory{} = rewritten} ->
        rewritten

      true ->
        enrich(memory, mission, opts)
    end
  end

  @spec keep?(Memory.t(), term(), keyword()) :: keep_result()
  def keep?(%Memory{} = memory, :code_agent, _opts) do
    if small_talk?(memory.text) and not technical_signal?(memory.text) do
      false
    else
      true
    end
  end

  def keep?(%Memory{}, _mission, _opts), do: true

  @spec priority(Memory.t(), term(), keyword()) :: float()
  def priority(%Memory{} = memory, :code_agent, _opts) do
    categories = code_agent_categories(memory.text)

    cond do
      :decision in categories or :bug in categories or :api_contract in categories -> 1.8
      :architecture in categories or :constraint in categories or :todo in categories -> 1.6
      :preference in categories or :project_state in categories -> 1.4
      categories != [] -> 1.2
      true -> 1.0
    end
  end

  def priority(%Memory{}, _mission, _opts), do: 1.0

  @spec extraction_profile(term()) :: keyword()
  def extraction_profile(:code_agent) do
    [
      extraction_mode: :technical,
      remember: [
        :architecture,
        :bug,
        :api_contract,
        :constraint,
        :todo,
        :preference,
        :project_state,
        :decision
      ],
      ignore: [:greeting, :acknowledgement, :low_value_reaction]
    ]
  end

  def extraction_profile(_mission), do: []

  @spec apply_policy(Memory.t(), term(), keyword()) :: keep_result()
  defp apply_policy(memory, nil, _opts), do: {:rewrite, memory}

  defp apply_policy(memory, mission, opts) do
    policy = Keyword.get(opts, :mission_policy, __MODULE__)

    if policy == __MODULE__ do
      keep?(memory, mission, opts)
    else
      custom_keep(policy, memory, mission, opts)
    end
  end

  @spec custom_keep(module(), Memory.t(), term(), keyword()) :: keep_result()
  defp custom_keep(policy, memory, mission, opts) when is_atom(policy) do
    if Code.ensure_loaded?(policy) and function_exported?(policy, :keep?, 3) do
      policy.keep?(memory, mission, opts)
    else
      true
    end
  rescue
    _exception -> true
  catch
    _kind, _reason -> true
  end

  defp custom_keep(_policy, _memory, _mission, _opts), do: true

  @spec enrich(Memory.t(), term(), keyword()) :: Memory.t()
  defp enrich(%Memory{} = memory, nil, _opts), do: memory

  defp enrich(%Memory{} = memory, mission, opts) do
    policy = Keyword.get(opts, :mission_policy, __MODULE__)
    profile = policy_extraction_profile(policy, mission)
    priority = policy_priority(policy, memory, mission, opts)
    categories = mission_categories(mission, memory.text)
    tags = Enum.uniq(memory.tags ++ [:mission, mission] ++ categories)

    extraction_mode =
      memory.extraction_mode ||
        Keyword.get(profile, :extraction_mode) ||
        Map.get(memory.metadata, :extraction_mode)

    metadata =
      memory.metadata
      |> Map.put(:mission_policy, policy)
      |> Map.put(:mission_priority, priority)
      |> Map.put(:mission_categories, categories)
      |> Map.put(:extraction_profile, profile)
      |> maybe_put(:extraction_mode, extraction_mode)

    %{memory | tags: tags, metadata: metadata, extraction_mode: extraction_mode}
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  @spec policy_priority(module(), Memory.t(), term(), keyword()) :: float()
  defp policy_priority(policy, memory, mission, opts) do
    cond do
      policy == __MODULE__ ->
        priority(memory, mission, opts)

      is_atom(policy) and Code.ensure_loaded?(policy) and function_exported?(policy, :priority, 3) ->
        policy.priority(memory, mission, opts)

      true ->
        1.0
    end
  rescue
    _exception -> 1.0
  catch
    _kind, _reason -> 1.0
  end

  @spec policy_extraction_profile(module(), term()) :: keyword()
  defp policy_extraction_profile(policy, mission) do
    cond do
      policy == __MODULE__ ->
        extraction_profile(mission)

      is_atom(policy) and Code.ensure_loaded?(policy) and
          function_exported?(policy, :extraction_profile, 1) ->
        policy.extraction_profile(mission)

      true ->
        []
    end
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  @spec mission_categories(term(), binary()) :: [atom()]
  defp mission_categories(:code_agent, text), do: code_agent_categories(text)
  defp mission_categories(_mission, _text), do: []

  @spec small_talk?(binary()) :: boolean()
  defp small_talk?(text) do
    normalized = normalize(text)

    Regex.match?(
      ~r/^(hi|hello|hey|thanks|thank you|ok|okay|cool|great|nice|awesome|lol|haha|yep|yes|no|sure|sounds good|got it|roger)[.!?\s]*$/iu,
      normalized
    ) or
      (String.length(normalized) <= 24 and
         Regex.match?(~r/\b(hi|hello|hey|thanks|ok|okay|cool|great|nice|awesome)\b/iu, normalized))
  end

  @spec technical_signal?(binary()) :: boolean()
  defp technical_signal?(text), do: code_agent_categories(text) != []

  @spec code_agent_categories(binary()) :: [atom()]
  defp code_agent_categories(text) do
    [
      {:architecture,
       ~r/\b(architecture|architectural|design|module|adapter|genserver|ets|service|dependency|elixir-native|native architecture)\b/iu},
      {:decision,
       ~r/\b(decision|decided|choose|chosen|will use|use .* instead|adr|accepted)\b/iu},
      {:bug, ~r/\b(bug|failure|fails?|error|flaky|broken|regression|crash|exception|defect)\b/iu},
      {:api_contract,
       ~r/\b(api|contract|schema|endpoint|callback|interface|public type|wire shape)\b/iu},
      {:constraint,
       ~r/\b(constraint|must|must not|cannot|can't|should|should not|requirement|compatibility)\b/iu},
      {:todo, ~r/\b(todo|fix|implement|follow[- ]?up|next step|task)\b/iu},
      {:preference, ~r/\b(prefers?|preference|avoid|likes?|wants?|favor|favour)\b/iu},
      {:project_state,
       ~r/\b(blocked by|status|current state|moving toward|moving away|direction|roadmap|deprecated)\b/iu}
    ]
    |> Enum.flat_map(fn {category, pattern} ->
      if Regex.match?(pattern, text), do: [category], else: []
    end)
  end

  @spec normalize(binary()) :: binary()
  defp normalize(text), do: text |> String.trim() |> String.downcase()
end
