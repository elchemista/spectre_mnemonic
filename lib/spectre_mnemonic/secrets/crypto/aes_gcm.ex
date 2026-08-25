defmodule SpectreMnemonic.Secrets.Crypto.AESGCM do
  @moduledoc """
  Built-in AES-256-GCM crypto adapter for secret moments.

  The adapter expects a 32-byte key from `:secret_key`, application config, or
  `:secret_key_fun`. Key functions may have arity 0 or 1; arity 1 receives the
  encryption/decryption context.
  """

  @behaviour SpectreMnemonic.Secrets.Crypto.Adapter

  alias SpectreMnemonic.Memory.Secret

  @algorithm :aes_256_gcm
  @iv_bytes 12
  @key_bytes 32
  @aad_prefix "spectre-mnemonic-secret:v2:"

  @impl SpectreMnemonic.Secrets.Crypto.Adapter
  def encrypt(plaintext, context, opts) when is_binary(plaintext) do
    # AES-GCM is intentionally boring here: random IV, AAD from stable ids, and
    # no homebrew crypto dance. La sicurezza non fa cabaret.
    with {:ok, key} <- key(context, opts) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      aad = context_aad(context)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

      {:ok,
       %{
         algorithm: @algorithm,
         ciphertext: ciphertext,
         iv: iv,
         tag: tag,
         aad: aad
       }}
    end
  rescue
    exception -> secret_crypto_error(exception)
  catch
    kind, reason -> {:error, {:secret_crypto_failed, {kind, reason}}}
  end

  def encrypt(plaintext, context, opts), do: encrypt(inspect(plaintext), context, opts)

  @impl SpectreMnemonic.Secrets.Crypto.Adapter
  def decrypt(%Secret{} = secret, context, opts) do
    with :ok <- supported_algorithm(secret.algorithm),
         :ok <- matching_aad(secret.aad, context),
         {:ok, key} <- key(context, opts) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             secret.iv,
             secret.ciphertext,
             secret.aad,
             secret.tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :invalid_secret_ciphertext}
      end
    end
  rescue
    _exception -> {:error, :invalid_secret_ciphertext}
  catch
    _kind, _reason -> {:error, :invalid_secret_ciphertext}
  end

  @spec key(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp key(context, opts) do
    context
    |> key_source(opts)
    |> normalize_key()
  end

  @spec key_source(map(), keyword()) :: term()
  defp key_source(context, opts) do
    configured_key = Application.get_env(:spectre_mnemonic, :secret_key)
    configured_fun = Application.get_env(:spectre_mnemonic, :secret_key_fun)

    cond do
      not is_nil(configured_key) -> configured_key
      not is_nil(configured_fun) -> key_from_fun(configured_fun, context)
      not is_nil(Keyword.get(opts, :secret_key)) -> Keyword.get(opts, :secret_key)
      true -> key_from_fun(Keyword.get(opts, :secret_key_fun), context)
    end
  end

  @spec key_from_fun(term(), map()) :: term()
  defp key_from_fun(fun, _context) when is_function(fun, 0), do: fun.()
  defp key_from_fun(fun, context) when is_function(fun, 1), do: fun.(context)
  defp key_from_fun(nil, _context), do: nil
  defp key_from_fun(invalid, _context), do: invalid

  @spec normalize_key(term()) :: {:ok, binary()} | {:error, term()}
  defp normalize_key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: {:ok, key}
  defp normalize_key(nil), do: {:error, :secret_key_not_configured}
  defp normalize_key(_other), do: {:error, {:invalid_secret_key, expected_bytes: @key_bytes}}

  @doc false
  @spec context_aad(map()) :: binary()
  def context_aad(context) do
    stable_context =
      {
        Map.get(context, :namespace),
        Map.get(context, :scope),
        Map.get(context, :secret_id),
        Map.get(context, :memory_id),
        Map.get(context, :label)
      }

    digest =
      stable_context
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    @aad_prefix <> digest
  end

  @spec supported_algorithm(atom()) :: :ok | {:error, term()}
  defp supported_algorithm(@algorithm), do: :ok
  defp supported_algorithm(other), do: {:error, {:unsupported_secret_algorithm, other}}

  @spec matching_aad(term(), map()) :: :ok | {:error, :secret_context_mismatch}
  defp matching_aad(stored, context) when is_binary(stored) do
    expected = context_aad(context)
    legacy = legacy_aad(context)

    if secure_equal?(stored, expected) or secure_equal?(stored, legacy) do
      :ok
    else
      {:error, :secret_context_mismatch}
    end
  end

  defp matching_aad(_stored, _context), do: {:error, :secret_context_mismatch}

  @spec legacy_aad(map()) :: binary()
  defp legacy_aad(context) do
    [
      Map.get(context, :namespace),
      inspect(Map.get(context, :scope)),
      Map.get(context, :secret_id),
      Map.get(context, :memory_id),
      Map.get(context, :label)
    ]
    |> Enum.map_join(":", &to_string(&1 || ""))
  end

  @spec secure_equal?(binary(), binary()) :: boolean()
  defp secure_equal?(left, right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  @spec secret_crypto_error(Exception.t()) :: {:error, term()}
  defp secret_crypto_error(exception) do
    {:error, {:secret_crypto_failed, {exception.__struct__, Exception.message(exception)}}}
  end
end
