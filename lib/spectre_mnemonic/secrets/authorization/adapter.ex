defmodule SpectreMnemonic.Secrets.Authorization.Adapter do
  @moduledoc """
  Behaviour for application-defined secret reveal authorization.

  Applications decide what "authorization" means: biometric unlock, e-mail
  challenge, user password, active session, signed request, OS keychain prompt,
  or any other policy. SpectreMnemonic only asks for a grant before decrypting.
  """

  @typedoc """
  Authorization request built by the library before reveal.

  The request includes `:operation`, `:secret_id`, `:memory_id`, `:signal_id`,
  `:label`, `:metadata`, and caller-provided `:authorization_context`.
  """
  @type request :: map()

  @typedoc "Application-specific authorization grant returned on success."
  @type grant :: map()

  @doc """
  Authorizes a secret reveal request.

  Return `{:ok, grant}` when the caller may receive plaintext. Return
  `{:error, reason}` to keep the secret locked in recall packets.
  """
  @callback authorize(request(), opts :: keyword()) :: {:ok, grant()} | {:error, term()}
end
