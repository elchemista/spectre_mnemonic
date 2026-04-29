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

  @impl true
  def encrypt(plaintext, context, opts) when is_binary(plaintext) do
    with {:ok, key} <- key(context, opts) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      aad = aad(context)

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
  end

  def encrypt(plaintext, context, opts), do: encrypt(inspect(plaintext), context, opts)

  @impl true
  def decrypt(%Secret{} = secret, context, opts) do
    with {:ok, key} <- key(context, opts),
         :ok <- supported_algorithm(secret.algorithm) do
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
    ArgumentError -> {:error, :invalid_secret_ciphertext}
  end

  @spec key(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp key(context, opts) do
    configured =
      Keyword.get(opts, :secret_key) ||
        Application.get_env(:spectre_mnemonic, :secret_key) ||
        key_from_fun(context, opts)

    normalize_key(configured)
  end

  @spec key_from_fun(map(), keyword()) :: term()
  defp key_from_fun(context, opts) do
    fun =
      Keyword.get(opts, :secret_key_fun) ||
        Application.get_env(:spectre_mnemonic, :secret_key_fun)

    cond do
      is_function(fun, 0) -> fun.()
      is_function(fun, 1) -> fun.(context)
      true -> nil
    end
  end

  @spec normalize_key(term()) :: {:ok, binary()} | {:error, term()}
  defp normalize_key(key) when is_binary(key) and byte_size(key) == @key_bytes, do: {:ok, key}
  defp normalize_key(nil), do: {:error, :secret_key_not_configured}
  defp normalize_key(_other), do: {:error, {:invalid_secret_key, expected_bytes: @key_bytes}}

  @spec aad(map()) :: binary()
  defp aad(context) do
    [
      Map.get(context, :secret_id),
      Map.get(context, :memory_id),
      Map.get(context, :label)
    ]
    |> Enum.map_join(":", &to_string(&1 || ""))
  end

  @spec supported_algorithm(atom()) :: :ok | {:error, term()}
  defp supported_algorithm(@algorithm), do: :ok
  defp supported_algorithm(other), do: {:error, {:unsupported_secret_algorithm, other}}
end
