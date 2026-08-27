import Config

# The library intentionally has no production DefaultEngine. Applications
# supervise explicit Engines; a global namespace starts only the 0.1.x
# compatibility Engine. Tests keep that compatibility path available.
if config_env() == :test do
  config :spectre_mnemonic,
    namespace: "spectre_mnemonic_test",
    json_library: Jason
end
