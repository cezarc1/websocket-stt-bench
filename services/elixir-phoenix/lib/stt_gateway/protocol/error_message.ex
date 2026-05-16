defmodule SttGateway.Protocol.ErrorMessage do
  @moduledoc false

  @error_type "error"

  # Variants other than :inference_request / :inference_response_parse are
  # forward-looking — current code only emits errors at those two stages — but
  # they're kept in the wire-shared schema so the shape is stable across the
  # three runtimes.
  @type stage ::
          :websocket_receive
          | :batch_flush
          | :inference_request
          | :inference_response_parse
          | :websocket_send

  @type kind ::
          :timeout
          | :pool_timeout
          | :http_5xx
          | :http_429
          | :connection_reset
          | :parse_error
          | :send_error

  @derive {JSON.Encoder,
           only: [
             :type,
             :stage,
             :kind,
             :message,
             :oldest_frame_seq,
             :newest_frame_seq,
             :frames,
             :audio_bytes,
             :oldest_age_ms,
             :newest_age_ms,
             :flush_lateness_ms,
             :inference_elapsed_ms,
             :inflight_gateway_batches,
             :gateway_buffer_frames,
             :inference_status,
             :retryable
           ]}
  defstruct [
    :type,
    :stage,
    :kind,
    :message,
    :oldest_frame_seq,
    :newest_frame_seq,
    :frames,
    :audio_bytes,
    :oldest_age_ms,
    :newest_age_ms,
    :flush_lateness_ms,
    :inference_elapsed_ms,
    :inflight_gateway_batches,
    :gateway_buffer_frames,
    :inference_status,
    :retryable
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          stage: String.t(),
          kind: String.t(),
          message: String.t(),
          oldest_frame_seq: non_neg_integer(),
          newest_frame_seq: non_neg_integer(),
          frames: non_neg_integer(),
          audio_bytes: non_neg_integer(),
          oldest_age_ms: float(),
          newest_age_ms: float(),
          flush_lateness_ms: float(),
          inference_elapsed_ms: float() | nil,
          inflight_gateway_batches: non_neg_integer(),
          gateway_buffer_frames: non_neg_integer(),
          inference_status: non_neg_integer() | nil,
          retryable: boolean()
        }

  @type fields :: %{
          stage: stage(),
          kind: kind(),
          message: String.t(),
          oldest_frame_seq: non_neg_integer(),
          newest_frame_seq: non_neg_integer(),
          frames: non_neg_integer(),
          audio_bytes: non_neg_integer(),
          oldest_age_ms: float(),
          newest_age_ms: float(),
          flush_lateness_ms: float(),
          inference_elapsed_ms: float() | nil,
          inflight_gateway_batches: non_neg_integer(),
          gateway_buffer_frames: non_neg_integer(),
          inference_status: non_neg_integer() | nil,
          retryable: boolean()
        }

  @spec new!(fields()) :: t()
  def new!(fields) do
    %__MODULE__{
      type: @error_type,
      stage: Atom.to_string(fields.stage),
      kind: Atom.to_string(fields.kind),
      message: fields.message,
      oldest_frame_seq: fields.oldest_frame_seq,
      newest_frame_seq: fields.newest_frame_seq,
      frames: fields.frames,
      audio_bytes: fields.audio_bytes,
      oldest_age_ms: fields.oldest_age_ms,
      newest_age_ms: fields.newest_age_ms,
      flush_lateness_ms: fields.flush_lateness_ms,
      inference_elapsed_ms: fields.inference_elapsed_ms,
      inflight_gateway_batches: fields.inflight_gateway_batches,
      gateway_buffer_frames: fields.gateway_buffer_frames,
      inference_status: fields.inference_status,
      retryable: fields.retryable
    }
  end

  @spec to_json!(t()) :: binary()
  def to_json!(%__MODULE__{} = message), do: JSON.encode!(message)
end
