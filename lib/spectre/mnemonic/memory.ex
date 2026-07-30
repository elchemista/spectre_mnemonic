defmodule Spectre.Mnemonic.Memory do
  @moduledoc """
  Adapter from Spectre's memory port to the Mnemonic engine selected by Stack.

  The adapter derives one opaque Mnemonic `:scope` from the installation's
  `isolate_by` declaration. Subject isolation accepts only an explicit
  canonical `Spectre.Subject`; channel actor ids are never inferred as
  cross-channel continuity. Values are used only as partition keys; journal
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

  alias Spectre.AgentRef
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Subject

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
      dimensions = Map.get(config, :isolate_by, [])

      options =
        config
        |> Map.get(:options, [])
        |> Keyword.merge(runtime_opts)

      with {:ok, options} <- normalize_agent_ref(options, agent),
           {:ok, options} <- normalize_subject(options, dimensions) do
        options =
          options
          |> normalize_namespace()
          |> configure_store(Map.get(config, :store))
          |> configure_scope(dimensions)

        {:ok, options}
      end
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
  defp dimension(:agent, opts) do
    case Keyword.get(opts, :agent_ref) do
      %AgentRef{} = agent_ref -> AgentRef.key(agent_ref)
      _missing -> Keyword.get(opts, :agent)
    end
  end

  defp dimension(:subject, opts),
    do: opts |> Keyword.fetch!(:subject) |> Subject.key()

  defp dimension(:conversation, opts) do
    Keyword.get(opts, :conversation) ||
      Keyword.get(opts, :origin_conversation_id) ||
      opts
      |> input()
      |> source_value(:conversation_id) ||
      Keyword.get(opts, :conversation_id) ||
      opts
      |> Keyword.get(:state)
      |> field(:conversation_id)
  end

  defp dimension(:flow, opts), do: Keyword.get(opts, :flow)

  defp dimension(:task, opts) do
    Keyword.get(opts, :task) || input_meta(opts, :task_id)
  end

  @spec normalize_subject(keyword(), [atom()]) :: {:ok, keyword()} | {:error, term()}
  defp normalize_subject(opts, dimensions) do
    case Keyword.fetch(opts, :subject) do
      {:ok, %Subject{} = subject} ->
        case Subject.validate(subject) do
          :ok -> {:ok, put_subject(opts, subject)}
          {:error, reason} -> {:error, {:invalid_mnemonic_subject, reason}}
        end

      {:ok, nil} ->
        if :subject in dimensions,
          do: {:error, :mnemonic_canonical_subject_required},
          else: {:ok, Keyword.delete(opts, :subject)}

      {:ok, value} ->
        {:ok, put_subject(opts, Subject.new(value))}

      :error ->
        if :subject in dimensions,
          do: {:error, :mnemonic_canonical_subject_required},
          else: {:ok, opts}
    end
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_mnemonic_subject, Exception.message(exception)}}
  end

  @spec normalize_agent_ref(keyword(), module()) :: {:ok, keyword()} | {:error, term()}
  defp normalize_agent_ref(opts, agent) do
    supplied = Keyword.get(opts, :agent_ref)

    authoritative =
      opts
      |> Keyword.get(:run_metadata)
      |> field(:agent_ref)

    with {:ok, supplied} <- validate_agent_ref(supplied),
         {:ok, authoritative} <- validate_agent_ref(authoritative),
         {:ok, agent_ref} <- reconcile_agent_refs(supplied, authoritative),
         :ok <- validate_agent_ref_definition(agent_ref, agent) do
      if agent_ref,
        do: {:ok, Keyword.put(opts, :agent_ref, agent_ref)},
        else: {:ok, Keyword.delete(opts, :agent_ref)}
    end
  end

  @spec validate_agent_ref(term()) :: {:ok, AgentRef.t() | nil} | {:error, term()}
  defp validate_agent_ref(nil), do: {:ok, nil}

  defp validate_agent_ref(%AgentRef{} = agent_ref) do
    case AgentRef.validate(agent_ref) do
      :ok -> {:ok, agent_ref}
      {:error, reason} -> {:error, {:invalid_mnemonic_agent_ref, reason}}
    end
  end

  defp validate_agent_ref(agent_ref),
    do: {:error, {:invalid_mnemonic_agent_ref, agent_ref}}

  @spec reconcile_agent_refs(AgentRef.t() | nil, AgentRef.t() | nil) ::
          {:ok, AgentRef.t() | nil} | {:error, :mnemonic_agent_ref_mismatch}
  defp reconcile_agent_refs(nil, nil), do: {:ok, nil}
  defp reconcile_agent_refs(%AgentRef{} = supplied, nil), do: {:ok, supplied}
  defp reconcile_agent_refs(nil, %AgentRef{} = authoritative), do: {:ok, authoritative}

  defp reconcile_agent_refs(%AgentRef{} = supplied, %AgentRef{} = authoritative) do
    if AgentRef.key(supplied) == AgentRef.key(authoritative),
      do: {:ok, authoritative},
      else: {:error, :mnemonic_agent_ref_mismatch}
  end

  @spec validate_agent_ref_definition(AgentRef.t() | nil, module()) ::
          :ok | {:error, term()}
  defp validate_agent_ref_definition(nil, _agent), do: :ok
  defp validate_agent_ref_definition(%AgentRef{definition: agent}, agent), do: :ok

  defp validate_agent_ref_definition(%AgentRef{definition: definition}, agent),
    do: {:error, {:mnemonic_agent_ref_definition_mismatch, definition, agent}}

  @spec put_subject(keyword(), Subject.t()) :: keyword()
  defp put_subject(opts, %Subject{} = subject) do
    opts
    |> Keyword.put(:subject, subject)
    |> Keyword.put(:subject_id, subject.id)
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
