defmodule SttGatewayWeb.WebSocketPlug do
  @moduledoc false

  import Plug.Conn

  @spec init(list()) :: list()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), list()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> WebSockAdapter.upgrade(SttGatewayWeb.SttWebSocket, [], timeout: 60_000)
    |> halt()
  end
end
