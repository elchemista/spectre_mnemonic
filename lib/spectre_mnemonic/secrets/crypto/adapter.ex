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
end
