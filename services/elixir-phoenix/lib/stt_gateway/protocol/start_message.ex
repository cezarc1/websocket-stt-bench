defmodule SttGateway.Protocol.StartMessage do
  @moduledoc false

  defstruct [:type]

  @type t :: %__MODULE__{type: String.t()}

  @spec from_json(binary()) :: {:ok, t()} | :error
  def from_json(payload) do
    with {:ok, decoded} <- JSON.decode(payload),
         {:ok, message} <- from_map(decoded) do
      {:ok, message}
    else
      _ -> :error
    end
  end

  @spec from_map(map()) :: {:ok, t()} | :error
  def from_map(%{"type" => "start"} = payload) when map_size(payload) == 1 do
    {:ok, %__MODULE__{type: "start"}}
  end

  def from_map(_payload), do: :error
end
