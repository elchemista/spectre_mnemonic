defmodule SpectreMnemonic.Integration.SecretCallbackTest do
  use SpectreMnemonic.MemoryCase

  alias SpectreMnemonic.Active.Focus
  alias SpectreMnemonic.Secrets
  alias SpectreMnemonic.Secrets.Crypto.AESGCM

  defmodule Authorization do
    def authorize(_request, opts), do: Keyword.get(opts, :authorization_result, {:ok, %{}})
  end

  defmodule Crypto do
    def encrypt(_plaintext, _context, opts), do: result(Keyword.fetch!(opts, :crypto_result))
    def decrypt(_secret, _context, opts), do: result(Keyword.fetch!(opts, :crypto_result))
    def shred(_context, opts), do: result(Keyword.fetch!(opts, :crypto_result))

    defp result({:raise, message}), do: raise(message)
    defp result({:throw, reason}), do: throw(reason)
    defp result(value), do: value
  end

  test "temporary reveal returns a callback result without unlocking the stored secret" do
    scope = {:tenant, "callback"}
    opts = [scope: scope, secret_key: :crypto.strong_rand_bytes(32)]

    assert {:ok, %{moment: secret}} =
             SpectreMnemonic.signal("private token", opts ++ [secret?: true, label: "token"])

    reveal_opts = opts ++ [authorization_adapter: Authorization]

    assert {:ok, 13} = Secrets.with_revealed(secret, reveal_opts, &byte_size/1)
    assert [%{locked?: true, revealed?: false} = stored] = Focus.moments(scope: scope)
    refute stored.text == "private token"

    assert {:error, {RuntimeError, "consumer failed"}} =
             Secrets.with_revealed(secret, reveal_opts, fn _ -> raise "consumer failed" end)

    assert {:error, {:throw, :consumer_failed}} =
             Secrets.with_revealed(secret, reveal_opts, fn _ -> throw(:consumer_failed) end)

    assert {:ok, revealed} = Secrets.reveal(secret, reveal_opts)
    assert Secrets.maybe_reveal(revealed, []) == revealed
    assert {:ok, "private token"} = Secrets.with_revealed(revealed, &Function.identity/1)
  end

  test "denied and out of scope requests never call the plaintext consumer" do
    assert {:ok, %{moment: secret}} =
             SpectreMnemonic.signal("restricted token",
               secret?: true,
               label: "token",
               scope: :owner,
               secret_key: :crypto.strong_rand_bytes(32)
             )

    callback = fn _ -> flunk("unauthorized callback invoked") end

    assert {:error, :denied} =
             Secrets.with_revealed(
               secret,
               [authorization_adapter: Authorization, authorization_result: {:error, :denied}],
               callback
             )

    assert {:error, :secret_out_of_scope} =
             Secrets.with_revealed(secret, [scope: :other], callback)

    assert %{locked?: true, authorization: %{status: :required}} =
             Secrets.maybe_reveal(secret, authorization_adapter: String)
  end

  test "crypto shredding reports unsupported, partial and failed adapter outcomes" do
    assert {:ok, %{supported?: false, performed?: false}} = Secrets.shred_report(:owner)
    report = %{supported?: true, performed?: false, reason: :key_shared}

    assert {:ok, ^report} =
             Secrets.shred_report(:owner, crypto_adapter: Crypto, crypto_result: {:ok, report})

    assert {:ok, %{supported?: true, performed?: true, result: :key_deleted}} =
             Secrets.shred_report(:owner,
               crypto_adapter: Crypto,
               crypto_result: {:ok, :key_deleted}
             )

    assert {:error, :key_store_down} =
             Secrets.shred_report(:owner,
               crypto_adapter: Crypto,
               crypto_result: {:error, :key_store_down}
             )

    assert {:error, {:unexpected_secret_crypto_result, :shred, :invalid}} =
             Secrets.shred(:owner, crypto_adapter: Crypto, crypto_result: :invalid)

    assert {:error, {:secret_crypto_failed, :shred, "key store unavailable"}} =
             Secrets.shred(:owner,
               crypto_adapter: Crypto,
               crypto_result: {:raise, "key store unavailable"}
             )

    assert {:error, {:secret_crypto_failed, :shred, {:throw, :offline}}} =
             Secrets.shred(:owner, crypto_adapter: Crypto, crypto_result: {:throw, :offline})
  end

  test "adapter encryption failures remain errors before a secret can be persisted" do
    for {result, reason} <- [
          {{:error, :offline}, :offline},
          {:invalid, {:unexpected_secret_crypto_result, :encrypt, :invalid}}
        ] do
      assert {:error, ^reason} =
               Secrets.encrypt("private", %{}, crypto_adapter: Crypto, crypto_result: result)
    end
  end

  test "AES encrypted versions and authentication data reject incompatible or damaged secrets" do
    key = :crypto.strong_rand_bytes(32)
    context = %{namespace: "spectre_mnemonic_test", scope: :versions, label: "token"}
    assert {:ok, encrypted} = AESGCM.encrypt("private", context, secret_key: key)
    secret = struct!(SpectreMnemonic.Memory.Secret, encrypted)

    for {changes, reason} <- [
          {%{algorithm: :unsupported}, {:unsupported_secret_algorithm, :unsupported}},
          {%{crypto_version: 99}, {:unsupported_secret_crypto_version, 99}},
          {%{aad_version: 99}, {:unsupported_secret_aad_version, 99}},
          {%{aad: nil}, :secret_context_mismatch},
          {%{iv: nil}, :invalid_secret_ciphertext}
        ] do
      assert {:error, ^reason} =
               AESGCM.decrypt(struct!(secret, changes), context, secret_key: key)
    end

    assert {:error, {:invalid_secret_key, expected_bytes: 32}} =
             AESGCM.encrypt("private", context, secret_key_fun: :not_a_function)

    assert {:ok, binary_payload} = AESGCM.encrypt(42, context, secret_key: key, key_id: nil)
    assert binary_payload.key_id == "default"
  end
end
