import { describe, expect, test } from "bun:test";

import {
  FRAME_BYTES,
  buildErrorMessage,
  buildPartialMessage,
  isPcmFrame,
  parseStartMessage,
  type Prediction,
} from "../src/protocol.ts";

describe("protocol schemas", () => {
  test("accepts only the exact start message", () => {
    expect(parseStartMessage('{"type":"start"}').success).toBe(true);
    expect(parseStartMessage('{"type":"start","extra":true}').success).toBe(false);
    expect(parseStartMessage('{"type":"partial"}').success).toBe(false);
    expect(parseStartMessage("not-json").success).toBe(false);
  });

  test("validates the fixed 640 byte PCM frame size", () => {
    expect(isPcmFrame(new Uint8Array(FRAME_BYTES))).toBe(true);
    expect(isPcmFrame(new Uint8Array(FRAME_BYTES - 1))).toBe(false);
    expect(isPcmFrame("text")).toBe(false);
  });

  test("serializes partial messages with the loadgen schema fields", () => {
    const prediction: Prediction = {
      rms: 2425.5,
      zero_crossings: 7,
      checksum: 1745339397,
      samples: 1280,
      transcript: "now",
      audio_bytes: 640,
    };

    const payload = JSON.parse(
      buildPartialMessage({
        oldestFrameSeq: 1,
        newestFrameSeq: 2,
        frames: 2,
        cpuPasses: 4,
        modelDelayMs: 75,
        flushLatenessMs: 1.23456,
        prediction,
      }),
    );

    expect(payload).toEqual({
      type: "partial",
      oldest_frame_seq: 1,
      newest_frame_seq: 2,
      frames: 2,
      rms: 2425.5,
      zero_crossings: 7,
      checksum: 1745339397,
      samples: 1280,
      transcript: "now",
      audio_bytes: 640,
      cpu_passes: 4,
      model_delay_ms: 75,
      flush_lateness_ms: 1.235,
      inflight_model_jobs: 0,
    });
  });

  test("serializes inference errors with the diagnostic schema fields", () => {
    const payload = JSON.parse(
      buildErrorMessage({
        stage: "inference_request",
        kind: "timeout",
        message: "timed out",
        oldestFrameSeq: 1,
        newestFrameSeq: 2,
        frames: 2,
        audioBytes: 1280,
        oldestAgeMs: 1200.12345,
        newestAgeMs: 200.12345,
        flushLatenessMs: 4.4444,
        inferenceElapsedMs: 2000.12345,
        inflightGatewayBatches: 1,
        gatewayBufferFrames: 3,
        inferenceStatus: null,
        retryable: true,
      }),
    );

    expect(payload).toEqual({
      type: "error",
      stage: "inference_request",
      kind: "timeout",
      message: "timed out",
      oldest_frame_seq: 1,
      newest_frame_seq: 2,
      frames: 2,
      audio_bytes: 1280,
      oldest_age_ms: 1200.123,
      newest_age_ms: 200.123,
      flush_lateness_ms: 4.444,
      inference_elapsed_ms: 2000.123,
      inflight_gateway_batches: 1,
      gateway_buffer_frames: 3,
      inference_status: null,
      retryable: true,
    });
  });
});
