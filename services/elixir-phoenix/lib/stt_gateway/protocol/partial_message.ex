defmodule SttGateway.Protocol.PartialMessage do
  @moduledoc false

  @partial_type "partial"

  @derive {JSON.Encoder,
           only: [
             :type,
             :oldest_frame_seq,
             :newest_frame_seq,
             :frames,
             :rms,
             :zero_crossings,
             :checksum,
             :samples,
             :transcript,
             :audio_bytes,
             :cpu_passes,
             :model_delay_ms,
             :flush_lateness_ms,
             :inflight_model_jobs
           ]}
  defstruct [
    :type,
    :oldest_frame_seq,
    :newest_frame_seq,
    :frames,
    :rms,
    :zero_crossings,
    :checksum,
    :samples,
    :transcript,
    :audio_bytes,
    :cpu_passes,
    :model_delay_ms,
    :flush_lateness_ms,
    :inflight_model_jobs
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          oldest_frame_seq: non_neg_integer(),
          newest_frame_seq: non_neg_integer(),
          frames: non_neg_integer(),
          rms: float(),
          zero_crossings: non_neg_integer(),
          checksum: non_neg_integer(),
          samples: non_neg_integer(),
          transcript: String.t(),
          audio_bytes: non_neg_integer(),
          cpu_passes: non_neg_integer(),
          model_delay_ms: non_neg_integer(),
          flush_lateness_ms: float(),
          inflight_model_jobs: non_neg_integer()
        }

  @type result :: %{
          rms: float(),
          zero_crossings: non_neg_integer(),
          checksum: non_neg_integer(),
          samples: non_neg_integer(),
          transcript: String.t(),
          audio_bytes: non_neg_integer()
        }

  @type context :: %{
          oldest_seq: non_neg_integer(),
          newest_seq: non_neg_integer(),
          frames: non_neg_integer(),
          cpu_passes: non_neg_integer(),
          model_delay_ms: non_neg_integer(),
          flush_lateness_ms: float(),
          inflight_model_jobs: non_neg_integer()
        }

  @spec new!(result(), context()) :: t()
  def new!(result, context) do
    %__MODULE__{
      type: @partial_type,
      oldest_frame_seq: context.oldest_seq,
      newest_frame_seq: context.newest_seq,
      frames: context.frames,
      rms: result.rms,
      zero_crossings: result.zero_crossings,
      checksum: result.checksum,
      samples: result.samples,
      transcript: result.transcript,
      audio_bytes: result.audio_bytes,
      cpu_passes: context.cpu_passes,
      model_delay_ms: context.model_delay_ms,
      flush_lateness_ms: context.flush_lateness_ms,
      inflight_model_jobs: context.inflight_model_jobs
    }
  end

  @spec to_json!(t()) :: binary()
  def to_json!(%__MODULE__{} = message), do: JSON.encode!(message)
end
