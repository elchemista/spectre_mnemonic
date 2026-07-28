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

  @spec remember(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def remember(payload, opts) when is_list(opts) do
    with {:ok, agent} <- agent(opts),
         {:ok, memory_opts} <- options(agent, opts) do
      result = SpectreMnemonic.remember(payload, memory_opts)
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
