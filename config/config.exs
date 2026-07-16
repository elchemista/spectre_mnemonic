import Config

# The library intentionally has no production default namespace. Applications
# must configure a stable namespace so persisted data cannot be mixed by
# accident. Tests use an explicit namespace before the OTP application starts.
if config_env() == :test do
  config :spectre_mnemonic, namespace: "spectre_mnemonic_test"
end
