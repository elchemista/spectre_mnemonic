defmodule Spectre.Mnemonic.ServerTool do
  @moduledoc """
  Explicit memory tools for the Spectre 0.4 Server.

  Recall is cognitive. Remember is exposed only with an explicit Stack host
  binding and is submitted to GAM by the core. `execute/3` is the technical
  adapter called by an already-authorized host executor; its portable result
  must be recorded before constructing GAM Outcome evidence. It does not grant
  authority, create a Candidate or retry a write with an uncertain result.
  """

  def prepare(:recall, [cue], _trusted) when is_binary(cue) or is_map(cue),
    do: {:ok, %{cue: cue}}

  def prepare(:remember, [observation], _trusted)
      when is_binary(observation) or is_map(observation),
      do: {:ok, %{observation: observation}}

  def prepare(_operation, _payload, _trusted), do: {:error, :invalid_mnemonic_request}

  def invoke(:recall, %{cue: cue}, %{service_context: context}) do
    with {:ok, opts} <- options(context), do: Spectre.Mnemonic.Memory.recall(cue, opts)
  end

  @doc "Invokes a write only from the host's admitted GAM executor and projects its result."
  def execute(:remember, %{observation: observation}, context) do
    with {:ok, opts} <- options(context) do
      result = Spectre.Mnemonic.Memory.remember(observation, opts)

      case project(:remember, result) do
        {:ok, projected} -> projected
        {:error, reason} -> {:error, {:mnemonic_projection_failed, reason}}
      end
    end
  end

  def project(operation, {:ok, packet}) when operation in [:recall, :remember] do
    {:ok, {:ok, Spectre.Mnemonic.ServerTool.Projection.to_data(packet)}}
  rescue
    ArgumentError -> {:error, :nonportable_mnemonic_result}
  end

  def project(_operation, {:error, reason}), do: {:ok, {:error, reason}}
  def project(_operation, _result), do: {:error, :invalid_mnemonic_result}

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
