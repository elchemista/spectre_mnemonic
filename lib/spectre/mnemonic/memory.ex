defmodule Spectre.Mnemonic.Memory do
  @moduledoc """
  Adapter from Spectre's memory port to the Mnemonic engine selected by Stack.

  The adapter derives one opaque Mnemonic `:scope` from the installation's
  `isolate_by` declaration. Values are used only as partition keys; journal
  records contain dimension names and outcomes, never subjects or content.
  """

  @spec recall(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def recall(cue, opts) when is_list(opts) do
    with {:ok, agent} <- agent(opts),
         {:ok, memory_opts} <- options(agent, opts) do
      result = SpectreMnemonic.recall(cue, memory_opts)
      record(agent, :mnemonic_recall, result, memory_opts)
      result
    end
  end

  alias Spectre.Input
  alias Spectre.Result

  @spec remember(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def remember(payload, opts) when is_list(opts) do
    with {:ok, agent} <- agent(opts),
         {:ok, memory_opts} <- options(agent, opts) do
      result = remember_payload(normalize_payload(payload, agent), durable(memory_opts))
      record(agent, :mnemonic_remember, result, memory_opts)
      result
    end
  end

  @doc """
  Persists a committed Spectre turn through the explicit memory callback.

  The four-argument callback keeps Run continuation data separate from the
  memory engine. Mnemonic receives the committed logical turn only after each
  `advance/2` or `resume/3`, and runtime handles are resolved from `opts` for
  that call rather than retained in `Spectre.Run`.
  """
  @spec remember(Input.t(), Result.t(), module(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def remember(%Input{} = input, %Result{} = result, agent, opts)
      when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    runtime_opts =
      Keyword.merge(opts,
        input: input,
        state: result.state,
        result: result,
        agent: agent
      )

    payload = turn_payload(input, result, agent)

    with {:ok, memory_opts} <- options(agent, runtime_opts) do
      result = remember_payload(payload, durable(memory_opts))
      record(agent, :mnemonic_remember, result, memory_opts)
      result
    end
  end

  @doc """
  Resolves the effective engine options for diagnostics and custom integrations.
  """
  @spec options(module(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def options(agent, runtime_opts \\ []) when is_atom(agent) and is_list(runtime_opts) do
    with {:ok, config} <- Spectre.Mnemonic.config(agent) do
      options =
        config
        |> Map.get(:options, [])
        |> Keyword.merge(runtime_opts)
        |> normalize_namespace()
        |> configure_store(Map.get(config, :store))
        |> configure_scope(Map.get(config, :isolate_by, []))

      {:ok, options}
    end
  end

  @spec configure_store(keyword(), module() | nil) :: keyword()
  defp configure_store(opts, nil), do: opts

  defp configure_store(opts, store) when is_atom(store) and not is_nil(store) do
    persistent =
      opts
      |> Keyword.get(:persistent_memory, [])
      |> Keyword.put(
        :stores,
        [[id: :spectre_stack, adapter: store, role: :primary]]
      )

    Keyword.put(opts, :persistent_memory, persistent)
  end

  @spec configure_scope(keyword(), [atom()]) :: keyword()
  defp configure_scope(opts, []), do: opts

  defp configure_scope(opts, dimensions) when is_list(dimensions) do
    partition = Enum.map(dimensions, &{&1, dimension(&1, opts)})
    Keyword.put(opts, :scope, {:spectre, partition})
  end

  @spec durable(keyword()) :: keyword()
  defp durable(opts), do: Keyword.put(opts, :persist?, true)

  @spec normalize_payload(term(), module()) :: term()
  defp normalize_payload(%{input: %Input{} = input} = payload, agent) do
    result = %Result{
      input: input,
      reply_text: Map.get(payload, :reply_text, ""),
      route: Map.get(payload, :route),
      state: Map.get(payload, :state),
      effects: Map.get(payload, :effects, []),
      awaitables: Map.get(payload, :awaitables, []),
      events: Map.get(payload, :events, [])
    }

    turn_payload(input, result, agent)
  end

  defp normalize_payload(payload, _agent), do: payload

  @spec remember_payload(term(), keyword()) :: {:ok, term()} | {:error, term()}
  defp remember_payload(%{text: text, metadata: metadata, kind: kind}, opts)
       when is_binary(text) and is_map(metadata) and is_atom(kind) do
    SpectreMnemonic.remember(
      text,
      opts
      |> Keyword.put(:metadata, metadata)
      |> Keyword.put(:kind, kind)
    )
  end

  defp remember_payload(payload, opts), do: SpectreMnemonic.remember(payload, opts)

  @spec turn_payload(Input.t(), Result.t(), module()) :: map()
  defp turn_payload(%Input{} = input, %Result{} = result, agent) do
    transcript =
      [input.text, result.reply_text]
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.join("\n")

    %{
      text: transcript,
      kind: :conversation,
      metadata: %{
        source: :spectre,
        agent: inspect(agent),
        conversation_id: conversation_id(result.state),
        route: route_projection(result.route),
        effects: Enum.map(result.effects, &effect_projection/1),
        awaitables: Enum.map(result.awaitables, &awaitable_projection/1),
        events: Enum.map(result.events, &event_projection/1),
        run: run_projection(result.metadata)
      }
    }
  end

  @spec route_projection(term()) :: map() | nil
  defp route_projection(nil), do: nil

  defp route_projection(route) when is_map(route) do
    route
    |> Map.take([:label, :flow, :scope, :strategy, :confidence, :accepted?])
    |> Map.update(:scope, nil, &logical_id/1)
  end

  defp route_projection(_route), do: nil

  @spec effect_projection(term()) :: map()
  defp effect_projection(effect) when is_map(effect) do
    effect
    |> Map.take([:id, :kind, :name, :status, :mode])
    |> Map.update(:id, nil, &logical_id/1)
  end

  defp effect_projection(_effect), do: %{}

  @spec awaitable_projection(term()) :: map()
  defp awaitable_projection(awaitable) when is_map(awaitable) do
    awaitable
    |> Map.take([:id, :kind, :status, :subject_id])
    |> Map.update(:id, nil, &logical_id/1)
    |> Map.update(:subject_id, nil, &logical_id/1)
  end

  defp awaitable_projection(_awaitable), do: %{}

  @spec event_projection(term()) :: term()
  defp event_projection(%{type: type}), do: type
  defp event_projection(event) when is_atom(event) or is_binary(event), do: event
  defp event_projection(_event), do: :event

  @spec run_projection(map()) :: map() | nil
  defp run_projection(metadata) when is_map(metadata) do
    case Map.get(metadata, :run) do
      run when is_map(run) -> Map.take(run, [:id, :revision, :status, :cursor, :step_id])
      _other -> nil
    end
  end

  defp run_projection(_metadata), do: nil

  @spec conversation_id(term()) :: term()
  defp conversation_id(%{conversation_id: conversation_id}), do: logical_id(conversation_id)
  defp conversation_id(_state), do: nil

  @spec logical_id(term()) :: term()
  defp logical_id(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) or
              is_atom(value),
       do: value

  defp logical_id(value) when is_tuple(value) do
    values = value |> Tuple.to_list() |> Enum.map(&logical_id/1)
    if Enum.any?(values, &is_nil/1), do: nil, else: List.to_tuple(values)
  end

  defp logical_id(_value), do: nil

  @spec dimension(atom(), keyword()) :: term()
  defp dimension(:agent, opts), do: Keyword.get(opts, :agent)

  defp dimension(:subject, opts) do
    Keyword.get(opts, :subject) ||
      opts
      |> input()
      |> source_value(:actor_id) ||
      input_meta(opts, :subject_id)
  end

  defp dimension(:conversation, opts) do
    Keyword.get(opts, :conversation) ||
      opts
      |> Keyword.get(:state)
      |> field(:conversation_id) ||
      opts
      |> input()
      |> source_value(:conversation_id)
  end

  defp dimension(:flow, opts), do: Keyword.get(opts, :flow)

  defp dimension(:task, opts) do
    Keyword.get(opts, :task) || input_meta(opts, :task_id)
  end

  @spec normalize_namespace(keyword()) :: keyword()
  defp normalize_namespace(opts) do
    case Keyword.get(opts, :namespace) do
      namespace when is_atom(namespace) and not is_nil(namespace) ->
        Keyword.put(opts, :namespace, Atom.to_string(namespace))

      _other ->
        opts
    end
  end

  @spec agent(keyword()) :: {:ok, module()} | {:error, :mnemonic_agent_required}
  defp agent(opts) do
    case Keyword.get(opts, :agent) do
      agent when is_atom(agent) and not is_nil(agent) -> {:ok, agent}
      _other -> {:error, :mnemonic_agent_required}
    end
  end

  @spec input(keyword()) :: term()
  defp input(opts), do: Keyword.get(opts, :input)

  @spec input_meta(keyword(), atom()) :: term()
  defp input_meta(opts, key) do
    opts
    |> input()
    |> field(:meta)
    |> field(key)
  end

  @spec source_value(term(), atom()) :: term()
  defp source_value(input, key), do: input |> field(:source) |> field(key)

  @spec field(term(), atom()) :: term()
  defp field(value, key) when is_map(value), do: Map.get(value, key)
  defp field(_value, _key), do: nil

  @spec record(module(), atom(), term(), keyword()) :: :ok
  defp record(agent, event, result, opts) do
    outcome =
      case result do
        {:ok, _value} -> :ok
        {:error, {reason, _detail}} when is_atom(reason) -> reason
        {:error, reason} when is_atom(reason) -> reason
        {:error, _reason} -> :error
      end

    isolation =
      agent
      |> Spectre.Mnemonic.config()
      |> case do
        {:ok, config} -> Map.get(config, :isolate_by, [])
        {:error, _reason} -> []
      end

    _journal =
      Spectre.Journal.record(
        agent,
        event,
        %{outcome: outcome, isolation: isolation},
        Keyword.take(opts, [:journal])
      )

    :ok
  end
end
