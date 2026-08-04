import Config

if config_env() == :prod do
  {:ok, operations} = PaseoRelay.Config.load()

  config :paseo_relay,
    runtime: operations
end
