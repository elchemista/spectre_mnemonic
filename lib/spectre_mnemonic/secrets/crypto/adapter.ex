defmodule SpectreMnemonic.Secrets.Crypto.Adapter do
  @moduledoc """
  Behaviour for secret encryption providers.

  Custom adapters can delegate to a KMS, Vault, platform keychain, TPM-backed
  key, or another application-specific crypto boundary.
  """

  alias SpectreMnemonic.Memory.Secret

  @typedoc "Encrypted binary fields stored on `%SpectreMnemonic.Memory.Secret{}`."
  @type encrypted_payload :: %{
          required(:algorithm) => atom(),
          optional(:key_id) => binary(),
          optional(:key_version) => pos_integer(),
          optional(:crypto_version) => pos_integer(),
          optional(:aad_version) => pos_integer(),
          required(:ciphertext) => binary(),
          required(:iv) => binary(),
          required(:tag) => binary(),
          required(:aad) => binary()
        }

  @doc "Encrypts secret plaintext using the provided secret context."
  @callback encrypt(plaintext :: binary(), context :: map(), opts :: keyword()) ::
              {:ok, encrypted_payload()} | {:error, term()}

  @doc "Decrypts a locked secret and returns plaintext."
  @callback decrypt(Secret.t(), context :: map(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc "Destroys the key material for one namespace/scope partition when supported."
  @callback shred(context :: map(), opts :: keyword()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks shred: 2
end
