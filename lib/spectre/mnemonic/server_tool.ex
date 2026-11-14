if Code.ensure_loaded?(Spectre.Stack.Installable) do
  defmodule Spectre.Mnemonic.ServerTool do
    @moduledoc """
    Explicit memory tools for the Spectre 0.4 Server.

    Reads are cognitive and do not reinforce memory or reveal secrets. Writes
    are exposed only with an explicit Stack host
    binding and is submitted to GAM by the core. `execute/3` is the technical
    adapter called by an already-authorized host executor; its portable result
    must be recorded before constructing GAM Outcome evidence. It does not grant
    authority, create a Candidate or retry a write with an uncertain result.
    """

    alias Spectre.Mnemonic.Memory
    alias Spectre.Mnemonic.ServerTool.{Operations, Projection}

    @behaviour Spectre.Server.GAM.EffectAdapter

    @doc "Executes a registered write after admission; validation precedes the effect."
    @spec execute_effect(atom(), map(), map()) ::
            {:ok, term()} | {:error, :definitive_no_effect | :ambiguous, term()}
    def execute_effect(operation, request, context) do
      with fields when is_list(fields) <- Operations.fields(operation),
           true <- operation in Operations.writes(),
           values = Enum.map(fields, &Map.get(request, &1)),
           {:ok, _} <- Operations.prepare(operation, values ++ [Map.get(request, :options, [])]),
           {:ok, opts} <- options(context),
           {:ok, _} <- Memory.options(context.agent, opts) do
        case execute(operation, request, context) do
          {:ok, receipt} -> {:ok, receipt}
          :ok -> {:ok, %{completed: true}}
          {:error, reason} -> {:error, :ambiguous, reason}
        end
      else
        {:error, reason} -> {:error, :definitive_no_effect, reason}
        _ -> {:error, :definitive_no_effect, :invalid_mnemonic_write}
      end
    end

    @doc "Validates a closed operation and optional request options; identity is never input."
    @spec prepare(atom(), list(), map()) :: {:ok, map()} | {:error, term()}
    def prepare(operation, payload, _trusted), do: Operations.prepare(operation, payload)

    @doc "Runs a memory read in the authenticated Stack partition."
    @spec invoke(atom(), map(), map()) :: {:ok, term()} | {:error, term()}
    def invoke(operation, request, %{service_context: context}) do
      if operation in Operations.reads(),
        do: run(operation, request, context, :read),
        else: {:error, :mnemonic_write_requires_executor}
    end

    @doc "Runs a write only from the host's admitted GAM executor and projects its result."
    @spec execute(atom(), map(), map()) :: {:ok, term()} | :ok | {:error, term()}
    def execute(operation, request, context) do
      if operation in Operations.writes() do
        case project(operation, run(operation, request, context, :write)) do
          {:ok, projected} -> projected
          {:error, reason} -> {:error, {:mnemonic_projection_failed, reason}}
        end
      else
        {:error, :invalid_mnemonic_write}
      end
    end

    @doc "Projects reviewed memory records without runtime handles or plaintext secrets."
    @spec project(atom(), term()) :: {:ok, term()} | {:error, term()}
    def project(_operation, {:ok, value}) do
      {:ok, {:ok, Projection.to_data(value)}}
    rescue
      ArgumentError -> {:error, :nonportable_mnemonic_result}
    end

    def project(_operation, :ok), do: {:ok, :ok}
    def project(_operation, {:error, reason}), do: {:ok, {:error, reason}}
    def project(_operation, _result), do: {:error, :invalid_mnemonic_result}

    @spec run(atom(), map(), map(), :read | :write) :: term()
    defp run(operation, request, context, mode) do
      fields = Operations.fields(operation)
      values = Enum.map(fields, &Map.get(request, &1))
      request_opts = Map.get(request, :options, [])

      with {:ok, _} <- Operations.prepare(operation, values ++ [request_opts]),
           {:ok, opts} <- options(context),
           {:ok, opts} <- Memory.options(context.agent, opts) do
        opts = Keyword.merge(opts, request_opts)
        # Reads must not reinforce durable graph weights or mutate attention on retry.
        opts =
          if mode == :read,
            do:
              Keyword.merge(opts,
                reinforce?: false,
                plasticity?: false,
                recluster: false,
                reveal_secrets?: false
              ),
            else: Keyword.put(opts, :persist?, true)

        call(operation, values, opts)
      end
    end

    @spec call(atom(), list(), keyword()) :: term()
    defp call(:remember, [observation], opts),
      do: Memory.remember(observation, opts)

    # operation has been selected exclusively from Operations' closed catalogue.
    defp call(operation, values, opts), do: apply(SpectreMnemonic, operation, values ++ [opts])

    @spec options(map()) :: {:ok, keyword()} | {:error, atom()}
    defp options(context) do
      identity = Map.get(context, :identity, %{})

      scope =
        [
          agent: context.agent,
          input: Map.get(context, :input),
          subject: Map.get(identity, :subject),
          conversation: Map.get(identity, :conversation),
          flow: Map.get(context, :current_flow),
          task: Map.get(identity, :task)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      opts = context |> Map.get(:options, [])

      if Keyword.get(opts, :stack_runtime) do
        {:ok, opts |> Keyword.merge(scope) |> put_operation_id(Map.get(context, :command_id))}
      else
        {:error, :mnemonic_stack_runtime_required}
      end
    end

    # Preserve the admitted command's identity for durable correlation. Mnemonic
    # generates memory IDs while ingesting, so this is not whole-request replay
    # protection and does not authorize retries after an uncertain write.
    defp put_operation_id(opts, command_id) when is_binary(command_id) and command_id != "",
      do: Keyword.put_new(opts, :operation_id, command_id)

    defp put_operation_id(opts, _command_id), do: opts
  end
end
