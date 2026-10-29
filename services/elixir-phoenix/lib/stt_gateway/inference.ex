defmodule SttGateway.Inference do
  @moduledoc false

  alias SttGateway.Protocol.ErrorMessage

  require Logger

  @type partial_context :: %{
          oldest_seq: non_neg_integer(),
          newest_seq: non_neg_integer(),
          frames: non_neg_integer(),
          flush_lateness_ms: float(),
          oldest_received_at_us: integer(),
          newest_received_at_us: integer()
        }

  @type inference_result :: %{
          rms: float(),
          zero_crossings: non_neg_integer(),
          checksum: non_neg_integer(),
          samples: non_neg_integer(),
          transcript: String.t(),
          audio_bytes: non_neg_integer()
        }

  @type error_payload :: %{
          stage: ErrorMessage.stage(),
          kind: ErrorMessage.kind(),
          message: String.t(),
          inference_status: non_neg_integer() | nil,
          inference_elapsed_ms: float() | nil,
          retryable: boolean()
        }

  @type result :: {:ok, inference_result()} | {:error, error_payload()}

  @spec request_async(iodata(), non_neg_integer(), partial_context(), pid(), String.t(), atom()) ::
          :ok
  def request_async(body, cpu_passes, context, caller, inference_url, finch_name) do
    Task.start(fn -> run(body, cpu_passes, context, caller, inference_url, finch_name) end)
    :ok
  end

  @spec run(iodata(), non_neg_integer(), partial_context(), pid(), String.t(), atom()) :: :ok
  defp run(body, cpu_passes, context, caller, inference_url, finch_name) do
    request =
      Finch.build(
        :post,
        "#{inference_url}/infer",
        [{"x-cpu-passes", Integer.to_string(cpu_passes)}],
        body
      )

    started_at = System.monotonic_time(:microsecond)
    result = call_inference(request, finch_name, started_at)
    send(caller, {:compute_finished, result, context})
    :ok
  end

  # The socket's `busy?` flag is only cleared by :compute_finished, so `run/6`
  # must report on every path: nothing below may raise or exit.
  @spec call_inference(Finch.Request.t(), atom(), integer()) :: result()
  defp call_inference(request, finch_name, started_at) do
    case safe_request(request, finch_name) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        decode_body(body, started_at)

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("inference returned status #{status}")
        {:error, status_error(status, started_at)}

      {:error, error} ->
        Logger.warning("inference call failed: #{inspect(error)}")
        {:error, transport_error(error, started_at)}

      {:crashed, message} ->
        Logger.warning(message)
        # No HTTP response was obtained, so this is a failed request at the
        # transport layer (e.g. the Finch pool process exited). Like the Rust
        # and Python gateways' fallback for unclassified request errors, that
        # is reported as a retryable connection_reset.
        {:error,
         make_error_payload(:inference_request, :connection_reset, message, nil, started_at, true)}
    end
  end

  @spec safe_request(Finch.Request.t(), atom()) ::
          {:ok, Finch.Response.t()} | {:error, Exception.t()} | {:crashed, String.t()}
  defp safe_request(request, finch_name) do
    Finch.request(request, finch_name, receive_timeout: 2_000, pool_timeout: 1_000)
  catch
    kind, reason ->
      {:crashed, "inference request crashed: " <> Exception.format_banner(kind, reason)}
  end

  @spec decode_body(binary(), integer()) :: result()
  defp decode_body(body, started_at) do
    case JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, build_result(decoded)}

      {:ok, other} ->
        message = "inference response is not a JSON object: #{inspect(other, limit: 5)}"
        Logger.warning(message)

        {:error,
         make_error_payload(
           :inference_response_parse,
           :parse_error,
           message,
           200,
           started_at,
           false
         )}

      {:error, decode_error} ->
        Logger.warning("inference response decode failed: #{inspect(decode_error)}")

        {:error,
         make_error_payload(
           :inference_response_parse,
           :parse_error,
           inspect(decode_error),
           200,
           started_at,
           false
         )}
    end
  end

  @spec status_error(non_neg_integer(), integer()) :: error_payload()
  defp status_error(status, started_at) do
    {kind, retryable} =
      cond do
        status == 429 -> {:http_429, true}
        status in 500..599 -> {:http_5xx, true}
        true -> {:http_5xx, false}
      end

    make_error_payload(
      :inference_request,
      kind,
      "inference returned status #{status}",
      status,
      started_at,
      retryable
    )
  end

  @spec transport_error(term(), integer()) :: error_payload()
  defp transport_error(error, started_at) do
    {kind, message} =
      case error do
        %Mint.TransportError{reason: :timeout} -> {:timeout, "inference request timed out"}
        _ -> {:connection_reset, inspect(error)}
      end

    make_error_payload(:inference_request, kind, message, nil, started_at, true)
  end

  @spec make_error_payload(
          ErrorMessage.stage(),
          ErrorMessage.kind(),
          String.t(),
          non_neg_integer() | nil,
          integer(),
          boolean()
        ) :: error_payload()
  defp make_error_payload(stage, kind, message, inference_status, started_at, retryable) do
    %{
      stage: stage,
      kind: kind,
      message: message,
      inference_status: inference_status,
      inference_elapsed_ms: elapsed_ms_since(started_at),
      retryable: retryable
    }
  end

  @spec build_result(map()) :: inference_result()
  defp build_result(decoded) do
    %{
      rms: decoded["rms"],
      zero_crossings: decoded["zero_crossings"],
      checksum: decoded["checksum"],
      samples: decoded["samples"],
      transcript: decoded["transcript"],
      audio_bytes: decoded["audio_bytes"]
    }
  end

  @spec elapsed_ms_since(integer()) :: float()
  defp elapsed_ms_since(started_at_us) do
    (System.monotonic_time(:microsecond) - started_at_us) / 1000.0
  end
end
