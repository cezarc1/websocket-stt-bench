import Config

config :stt_gateway, SttGatewayWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true,
  secret_key_base: String.duplicate("a", 64),
  render_errors: [formats: [json: SttGatewayWeb.ErrorJSON], layout: false],
  pubsub_server: nil

config :phoenix, :json_library, JSON
config :logger, level: :info
