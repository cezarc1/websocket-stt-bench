defmodule SttGatewayWeb.ErrorJSON do
  @spec render(atom(), map()) :: map()
  def render(template, _assigns) do
    %{error: Phoenix.Controller.status_message_from_template(template)}
  end
end
