defmodule SpectreMnemonic.Integration.SecretsHardeningTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Memory.Secret
  alias SpectreMnemonic.Secrets.Crypto.AESGCM

  test "AES-GCM binds ciphertext to the current secret context" do
    context = %{
      namespace: "spectre_mnemonic_test",
      scope: {:project, "alpha"},
      secret_id: "sec-context",
      memory_id: "mom-context",
      label: "production token"
    }

    assert {:ok, encrypted} = AESGCM.encrypt("secret", context, secret_key: secret_key())
    secret = secret(encrypted, context)

    assert {:ok, "secret"} = AESGCM.decrypt(secret, context, secret_key: secret_key())

    assert {:error, :secret_context_mismatch} =
             AESGCM.decrypt(secret, %{context | label: "different token"},
               secret_key: secret_key()
             )
  end

  test "secret AAD is versioned and deterministic instead of depending on Inspect" do
    context = %{
      namespace: "spectre_mnemonic_test",
      scope: %{tenant: "alpha", subject: 42},
      secret_id: "sec-stable",
      memory_id: "mom-stable",
      label: "stable token"
    }

    assert {:ok, first} = AESGCM.encrypt("secret", context, secret_key: secret_key())
    assert {:ok, second} = AESGCM.encrypt("secret", context, secret_key: secret_key())

    assert first.aad == second.aad
    assert String.starts_with?(first.aad, "spectre-mnemonic-secret:v2:")
    refute String.contains?(first.aad, "stable token")
    refute String.contains?(first.aad, "alpha")
  end

  test "reveal derives the stored scope and configured security cannot be overridden per call" do
    Application.put_env(:spectre_mnemonic, :secret_key, secret_key())

    Application.put_env(
      :spectre_mnemonic,
      :secret_authorization_adapter,
      __MODULE__.AllowAuthorization
    )

    Application.put_env(
      :spectre_mnemonic,
      :secret_crypto_adapter,
      AESGCM
    )

    scope = {:tenant, "scoped-secret"}

    assert {:ok, %{moment: secret}} =
             SpectreMnemonic.signal("scoped plaintext",
               scope: scope,
               secret?: true,
               label: "scoped token",
               secret_key: <<0::256>>,
               crypto_adapter: "not-a-module"
             )

    rendered = inspect(secret)
    refute rendered =~ "ciphertext:"
    refute rendered =~ "iv:"
    refute rendered =~ "tag:"
    refute rendered =~ "aad:"

    assert {:ok, revealed} =
             SpectreMnemonic.reveal(secret,
               secret_key: <<0::256>>,
               authorization_adapter: __MODULE__.DenyAuthorization,
               crypto_adapter: __MODULE__.MalformedCrypto
             )

    assert revealed.scope == scope
    assert revealed.text == "scoped plaintext"
  end

  test "key provider failures are returned instead of escaping" do
    context = %{secret_id: "sec-key", memory_id: "mom-key", label: "key"}

    assert {:error, {:secret_crypto_failed, {RuntimeError, "key provider failed"}}} =
             AESGCM.encrypt("secret", context,
               secret_key_fun: fn -> raise "key provider failed" end
             )

    assert {:error, {:secret_crypto_failed, {:throw, :key_provider_failed}}} =
             AESGCM.encrypt("secret", context,
               secret_key_fun: fn -> throw(:key_provider_failed) end
             )
  end

  test "invalid crypto adapters and payloads do not crash active focus" do
    assert {:error, {:secret_crypto_not_available, "not-a-module", :encrypt}} =
             SpectreMnemonic.signal("secret",
               secret?: true,
               label: "invalid adapter",
               crypto_adapter: "not-a-module"
             )

    assert {:error, :invalid_encrypted_secret} =
             SpectreMnemonic.signal("secret",
               secret?: true,
               label: "invalid payload",
               crypto_adapter: __MODULE__.MalformedCrypto
             )

    assert {:error, {:secret_crypto_failed, :encrypt, {RuntimeError, "encrypt failed"}}} =
             SpectreMnemonic.signal("secret",
               secret?: true,
               label: "raising adapter",
               crypto_adapter: __MODULE__.RaisingCrypto
             )

    assert {:error, {:secret_crypto_failed, :encrypt, {:throw, :encrypt_failed}}} =
             SpectreMnemonic.signal("secret",
               secret?: true,
               label: "throwing adapter",
               crypto_adapter: __MODULE__.ThrowingCrypto
             )

    refute Process.whereis(Focus)
    assert {:ok, %{moment: _moment}} = SpectreMnemonic.signal("ordinary memory")
  end

  test "unexpected authorization and decryption results stay structured" do
    assert {:ok, %{moment: secret}} =
             SpectreMnemonic.signal("secret",
               secret?: true,
               label: "structured boundary",
               secret_key: secret_key()
             )

    assert {:error, {:unexpected_authorization_result, {:ok, :yes}}} =
             SpectreMnemonic.reveal(secret,
               authorization_adapter: __MODULE__.InvalidAuthorization,
               secret_key: secret_key()
             )

    assert {:error, {:unexpected_secret_crypto_result, :decrypt, {:ok, :not_binary}}} =
             SpectreMnemonic.reveal(secret,
               authorization_adapter: __MODULE__.AllowAuthorization,
               crypto_adapter: __MODULE__.MalformedCrypto
             )

    assert {:error, {:secret_crypto_failed, :decrypt, {RuntimeError, "decrypt failed"}}} =
             SpectreMnemonic.reveal(secret,
               authorization_adapter: __MODULE__.AllowAuthorization,
               crypto_adapter: __MODULE__.RaisingCrypto
             )

    assert {:error, {RuntimeError, "authorization failed"}} =
             SpectreMnemonic.reveal(secret,
               authorization_adapter: __MODULE__.RaisingAuthorization
             )
  end

  defp secret(encrypted, context) do
    struct!(
      Secret,
      Map.merge(encrypted, %{
        id: context.memory_id,
        namespace: context.namespace,
        scope: context.scope,
        signal_id: "sig-context",
        secret_id: context.secret_id,
        label: context.label,
        text: "secret: #{context.label}",
        input: "secret: #{context.label}"
      })
    )
  end

  defp secret_key, do: :crypto.hash(:sha256, "mnemonic-secrets-hardening")

  defmodule MalformedCrypto do
    @behaviour SpectreMnemonic.Secrets.Crypto.Adapter

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def encrypt(_plaintext, _context, _opts), do: {:ok, %{}}

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def decrypt(_secret, _context, _opts), do: {:ok, :not_binary}
  end

  defmodule RaisingCrypto do
    @behaviour SpectreMnemonic.Secrets.Crypto.Adapter

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def encrypt(_plaintext, _context, _opts), do: raise("encrypt failed")

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def decrypt(_secret, _context, _opts), do: raise("decrypt failed")
  end

  defmodule ThrowingCrypto do
    @behaviour SpectreMnemonic.Secrets.Crypto.Adapter

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def encrypt(_plaintext, _context, _opts), do: throw(:encrypt_failed)

    @impl SpectreMnemonic.Secrets.Crypto.Adapter
    def decrypt(_secret, _context, _opts), do: throw(:decrypt_failed)
  end

  defmodule InvalidAuthorization do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl SpectreMnemonic.Secrets.Authorization.Adapter
    def authorize(_request, _opts), do: {:ok, :yes}
  end

  defmodule DenyAuthorization do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl SpectreMnemonic.Secrets.Authorization.Adapter
    def authorize(_request, _opts), do: {:error, :denied}
  end

  defmodule AllowAuthorization do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl SpectreMnemonic.Secrets.Authorization.Adapter
    def authorize(_request, _opts), do: {:ok, %{authorized?: true}}
  end

  defmodule RaisingAuthorization do
    @behaviour SpectreMnemonic.Secrets.Authorization.Adapter

    @impl SpectreMnemonic.Secrets.Authorization.Adapter
    def authorize(_request, _opts), do: raise("authorization failed")
  end
end
