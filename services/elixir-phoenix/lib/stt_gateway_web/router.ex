defmodule SttGatewayWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/" do
    pipe_through :api
    get "/health", SttGatewayWeb.HealthController, :show
  end

  forward "/ws/stt", SttGatewayWeb.WebSocketPlug
end
