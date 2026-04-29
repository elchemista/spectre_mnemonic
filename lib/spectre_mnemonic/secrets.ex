defmodule SpectreMnemonic.Secrets do
  @moduledoc false

  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Secrets.Crypto.AESGCM

  @doc "Encrypts plaintext with the configured crypto adapter."
  @spec encrypt(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def encrypt(plaintext, context, opts) do
    crypto_adapter(opts).encrypt(plaintext, context, opts)
  end

  @doc "Authorizes and decrypts a locked secret moment."
  @spec reveal(Secret.t(), keyword()) :: {:ok, Secret.t()} | {:error, term()}
  def reveal(%Secret{locked?: false} = secret, _opts), do: {:ok, secret}

  def reveal(%Secret{} = secret, opts) do
    request = authorization_request(secret, opts)

    with {:ok, adapter} <- authorization_adapter(opts),
         {:ok, grant} <- adapter.authorize(request, opts),
         {:ok, plaintext} <- crypto_adapter(opts).decrypt(secret, request, opts) do
      {:ok,
       %{
         secret
         | text: plaintext,
           input: plaintext,
           locked?: false,
           revealed?: true,
           authorization: %{status: :authorized, grant: grant, request: request},
           reveal: reveal_instruction()
       }}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc "Attempts to authorize and reveal a secret moment, returning it locked on denial."
  @spec maybe_reveal(Secret.t(), keyword()) :: Secret.t()
  def maybe_reveal(%Secret{locked?: false} = secret, _opts), do: secret

  def maybe_reveal(%Secret{} = secret, opts) do
    case reveal(secret, opts) do
      {:ok, revealed} -> revealed
      {:error, reason} -> lock_with_authorization(secret, reason, opts)
    end
  end

  def maybe_reveal(moment, _opts), do: moment

  @doc "Returns the standard public reveal instruction stored on locked secrets."
  @spec reveal_instruction :: map()
  def reveal_instruction do
    %{module: SpectreMnemonic, function: :reveal, arity: 2}
  end

  @spec crypto_adapter(keyword()) :: module()
  defp crypto_adapter(opts) do
    Keyword.get(opts, :crypto_adapter) ||
      Application.get_env(:spectre_mnemonic, :secret_crypto_adapter) ||
      AESGCM
  end

  @spec authorization_adapter(keyword()) ::
          {:ok, module()} | {:error, :authorization_not_configured}
  defp authorization_adapter(opts) do
    adapter =
      Keyword.get(opts, :authorization_adapter) ||
        Application.get_env(:spectre_mnemonic, :secret_authorization_adapter)

    cond do
      is_nil(adapter) ->
        {:error, :authorization_not_configured}

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :authorize, 2) ->
        {:ok, adapter}

      true ->
        {:error, {:authorization_not_available, adapter}}
    end
  end

  @spec authorization_request(Secret.t(), keyword()) :: map()
  defp authorization_request(secret, opts) do
    %{
      operation: :recall,
      secret_id: secret.secret_id,
      memory_id: secret.id,
      signal_id: secret.signal_id,
      label: secret.label,
      metadata: secret.metadata,
      authorization_context: Keyword.get(opts, :authorization_context)
    }
  end

  @spec lock_with_authorization(Secret.t(), term(), keyword()) :: Secret.t()
  defp lock_with_authorization(secret, reason, opts) do
    %{
      secret
      | locked?: true,
        revealed?: false,
        authorization: %{
          status: authorization_status(reason),
          reason: reason,
          request: authorization_request(secret, opts)
        },
        reveal: reveal_instruction()
    }
  end

  @spec authorization_status(term()) :: :required | :denied
  defp authorization_status(:authorization_not_configured), do: :required
  defp authorization_status({:authorization_not_available, _adapter}), do: :required
  defp authorization_status(_reason), do: :denied
end
