import Config

# runtime.exs runs at boot for releases (after the BEAM has loaded the
# release's compiled config). Anything that depends on env vars must live
# here, not in config/config.exs, so the value is read from the running
# container's environment rather than baked in at release-build time.
config :stt_gateway, SttGatewayWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4000")]

if config_env() == :prod do
  config :logger, level: :info
end
