defmodule SpectreMnemonic.Secrets do
  @moduledoc """
  Secret encryption and reveal orchestration.

  Secret moments keep plaintext out of recall by default. During ingestion the
  configured crypto adapter stores ciphertext and metadata. During recall,
  locked secrets remain placeholders unless `reveal/2` is called and the
  configured authorization adapter approves the request.

  Application code normally calls `SpectreMnemonic.reveal/2`; this module exists
  so adapters and lower-level tests can exercise the secret boundary directly.
  """

  alias SpectreMnemonic.Identity
  alias SpectreMnemonic.Memory.Scope
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Secrets.Crypto.AESGCM

  @doc """
  Encrypts plaintext with the configured crypto adapter.

  The context map is passed to key functions and crypto adapters. It should
  contain the stable identifiers and labels needed to audit or scope encryption.

  ## Example

      iex> SpectreMnemonic.Secrets.encrypt("sk_live_...", %{label: "Stripe key"}, [])
      {:ok, %{ciphertext: _ciphertext, iv: _iv, tag: _tag}}
  """
  @spec encrypt(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def encrypt(plaintext, context, opts) do
    with {:ok, adapter} <- crypto_adapter(opts, :encrypt),
         {:ok, encrypted} <- call_encrypt(adapter, plaintext, context, opts),
         :ok <- validate_encrypted_payload(encrypted) do
      {:ok, encrypted}
    end
  end

  @doc """
  Authorizes and decrypts a locked secret moment.

  The authorization adapter receives a request containing secret id, memory id,
  label, metadata, and optional authorization context. Only after authorization
  succeeds does the crypto adapter decrypt the ciphertext.

  ## Example

      iex> SpectreMnemonic.Secrets.reveal(secret, actor: "operator")
      {:ok, %SpectreMnemonic.Memory.Secret{locked?: false, revealed?: true}}
  """
  @spec reveal(Secret.t(), keyword()) :: {:ok, Secret.t()} | {:error, term()}
  def reveal(%Secret{} = secret, opts) do
    with {:ok, opts} <- Identity.put_namespace(opts),
         true <- Scope.match?(secret, opts) do
      do_reveal(secret, opts)
    else
      false -> {:error, :secret_out_of_scope}
      {:error, _reason} = error -> error
    end
  end

  @spec do_reveal(Secret.t(), keyword()) :: {:ok, Secret.t()} | {:error, term()}
  defp do_reveal(%Secret{locked?: false} = secret, _opts), do: {:ok, secret}

  defp do_reveal(%Secret{} = secret, opts) do
    # Recall can show that a secret exists. Plaintext needs authorization first.
    # The model does not get to wink and say it had a good reason.
    request = authorization_request(secret, opts)

    with {:ok, adapter} <- authorization_adapter(opts),
         {:ok, grant} <- authorize(adapter, request, opts),
         {:ok, crypto} <- crypto_adapter(opts, :decrypt),
         {:ok, plaintext} <- call_decrypt(crypto, secret, request, opts) do
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

  @doc """
  Attempts to authorize and reveal a secret moment, returning it locked on denial.

  Recall uses this helper so callers can opt into revealing secrets without
  turning authorization failures into recall failures. On denial, the returned
  secret includes authorization status and the public reveal instruction.
  """
  @spec maybe_reveal(Secret.t(), keyword()) :: Secret.t()
  def maybe_reveal(%Secret{locked?: false} = secret, _opts), do: secret

  def maybe_reveal(%Secret{} = secret, opts) do
    # Recall should not explode just because authorization said no. Return the
    # locked placeholder with the denial attached, like a tiny bureaucratic stamp.
    case reveal(secret, opts) do
      {:ok, revealed} -> revealed
      {:error, reason} -> lock_with_authorization(secret, reason, opts)
    end
  end

  def maybe_reveal(moment, _opts), do: moment

  @doc """
  Returns the standard public reveal instruction stored on locked secrets.

  UI and agent callers can expose this metadata to explain how a locked secret
  should be requested without embedding module names by hand.
  """
  @spec reveal_instruction :: map()
  def reveal_instruction do
    %{module: SpectreMnemonic, function: :reveal, arity: 2}
  end

  @spec crypto_adapter(keyword(), :encrypt | :decrypt) :: {:ok, module()} | {:error, term()}
  defp crypto_adapter(opts, operation) do
    adapter =
      Keyword.get(opts, :crypto_adapter) ||
        Application.get_env(:spectre_mnemonic, :secret_crypto_adapter) ||
        AESGCM

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, operation, 3) do
      {:ok, adapter}
    else
      {:error, {:secret_crypto_not_available, adapter, operation}}
    end
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

      is_atom(adapter) and Code.ensure_loaded?(adapter) and
          function_exported?(adapter, :authorize, 2) ->
        {:ok, adapter}

      true ->
        {:error, {:authorization_not_available, adapter}}
    end
  end

  @spec authorization_request(Secret.t(), keyword()) :: map()
  defp authorization_request(secret, opts) do
    %{
      operation: :recall,
      namespace: secret.namespace,
      scope: secret.scope,
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

  @spec call_encrypt(module(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp call_encrypt(adapter, plaintext, context, opts) do
    case adapter.encrypt(plaintext, context, opts) do
      {:ok, encrypted} when is_map(encrypted) -> {:ok, encrypted}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_secret_crypto_result, :encrypt, other}}
    end
  rescue
    exception -> adapter_failure(:encrypt, exception)
  catch
    kind, reason -> {:error, {:secret_crypto_failed, :encrypt, {kind, reason}}}
  end

  @spec call_decrypt(module(), Secret.t(), map(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  defp call_decrypt(adapter, secret, context, opts) do
    case adapter.decrypt(secret, context, opts) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_secret_crypto_result, :decrypt, other}}
    end
  rescue
    exception -> adapter_failure(:decrypt, exception)
  catch
    kind, reason -> {:error, {:secret_crypto_failed, :decrypt, {kind, reason}}}
  end

  @spec authorize(module(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defp authorize(adapter, request, opts) do
    case adapter.authorize(request, opts) do
      {:ok, grant} when is_map(grant) -> {:ok, grant}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_authorization_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec validate_encrypted_payload(map()) :: :ok | {:error, :invalid_encrypted_secret}
  defp validate_encrypted_payload(encrypted) do
    valid? =
      is_atom(Map.get(encrypted, :algorithm)) and
        Enum.all?([:ciphertext, :iv, :tag, :aad], fn key ->
          is_binary(Map.get(encrypted, key))
        end)

    if valid?, do: :ok, else: {:error, :invalid_encrypted_secret}
  end

  @spec adapter_failure(:encrypt | :decrypt, Exception.t()) :: {:error, term()}
  defp adapter_failure(operation, exception) do
    {:error,
     {:secret_crypto_failed, operation, {exception.__struct__, Exception.message(exception)}}}
  end
end
