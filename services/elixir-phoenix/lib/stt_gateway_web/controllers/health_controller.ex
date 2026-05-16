defmodule SttGatewayWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    json(conn, %{ok: true, runtime: "elixir-phoenix"})
  end
end
