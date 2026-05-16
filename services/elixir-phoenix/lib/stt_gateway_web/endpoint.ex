defmodule SttGatewayWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :stt_gateway

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: JSON

  plug SttGatewayWeb.Router
end
