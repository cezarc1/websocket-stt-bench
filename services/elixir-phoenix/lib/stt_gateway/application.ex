defmodule SttGateway.Application do
  @moduledoc false

  use Application

  @finch_name SttGateway.Finch
  # One HTTP/2 connection = one Finch pool process. When the run queue is full,
  # fair scheduling starves each pool process, so its replies sit unread until
  # request timeouts fire together; keep sessions per connection small (~2-5).
  @default_finch_pool_count 512

  def finch_name, do: @finch_name

  @impl true
  def start(_type, _args) do
    inference_url =
      System.get_env("INFERENCE_URL") || "http://inference-server:9000"

    Application.put_env(:stt_gateway, :inference_url, String.trim_trailing(inference_url, "/"))

    finch_pool_count = positive_integer_env("FINCH_POOL_COUNT", @default_finch_pool_count)

    SttGateway.RuntimeVersions.assert!(inference_url, finch_pool_count)

    children = [
      {Finch,
       name: @finch_name,
       pools: %{
         default: [
           protocols: [:http2],
           size: 1,
           count: finch_pool_count,
           conn_opts: [transport_opts: [timeout: 1_000]]
         ]
       }},
      SttGatewayWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SttGateway.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SttGatewayWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp positive_integer_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end
end
