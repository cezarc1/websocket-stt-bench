defmodule SttGatewayWeb.SttWebSocket.State do
  @moduledoc false

  @type frame :: {non_neg_integer(), binary(), integer()}

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          buffer: [frame()],
          # length(buffer), kept so the per-frame backlog check is O(1).
          buffered: non_neg_integer(),
          # See SttGatewayWeb.SttWebSocket.max_buffered_frames/3.
          max_buffered_frames: pos_integer(),
          cpu_passes: non_neg_integer(),
          model_delay_ms: non_neg_integer(),
          flush_interval_ms: pos_integer(),
          flush_phase_jitter_ms: non_neg_integer(),
          next_due_us: integer() | nil,
          busy?: boolean(),
          inference_url: String.t(),
          finch_name: atom()
        }

  defstruct seq: 0,
            buffer: [],
            buffered: 0,
            max_buffered_frames: 300,
            cpu_passes: 0,
            model_delay_ms: 0,
            flush_interval_ms: 1_000,
            flush_phase_jitter_ms: 0,
            next_due_us: nil,
            busy?: false,
            inference_url: "",
            finch_name: nil
end
