import * as v from "valibot";

import { FRAME_BYTES } from "./config.ts";

export { FRAME_BYTES };

export const CLOSE_PROTOCOL_ERROR = 1002;
export const CLOSE_UNSUPPORTED_DATA = 1003;
export const REASON_NEED_START = "first message must be start";
export const REASON_TEXT_AFTER_START = "expected binary PCM frames after start";
export const REASON_BAD_FRAME_SIZE = "expected 640 byte PCM frame";

export type ErrorStage =
  | "websocket_receive"
  | "batch_flush"
  | "inference_request"
  | "inference_response_parse"
  | "websocket_send";

export type ErrorKind =
  | "timeout"
  | "pool_timeout"
  | "http_5xx"
  | "http_429"
  | "connection_reset"
  | "parse_error"
  | "send_error";

const NonNegativeSafeIntegerSchema = v.pipe(v.number(), v.safeInteger(), v.minValue(0));
const PositiveSafeIntegerSchema = v.pipe(v.number(), v.safeInteger(), v.minValue(1));
const FiniteNumberSchema = v.pipe(v.number(), v.finite());

const StartMessageSchema = v.strictObject({
  type: v.literal("start"),
});

export const PredictionSchema = v.strictObject({
  rms: FiniteNumberSchema,
  zero_crossings: NonNegativeSafeIntegerSchema,
  checksum: NonNegativeSafeIntegerSchema,
  samples: PositiveSafeIntegerSchema,
  transcript: v.string(),
  audio_bytes: PositiveSafeIntegerSchema,
});

export type Prediction = v.InferOutput<typeof PredictionSchema>;

export type ParseResult<T> =
  | { readonly success: true; readonly output: T }
  | { readonly success: false; readonly message: string };

export interface Frame {
  readonly seq: number;
  readonly payload: Uint8Array;
  readonly receivedAtMs: number;
}

export interface PartialBuildInput {
  readonly oldestFrameSeq: number;
  readonly newestFrameSeq: number;
  readonly frames: number;
  readonly prediction: Prediction;
  readonly cpuPasses: number;
  readonly modelDelayMs: number;
  readonly flushLatenessMs: number;
}

export interface ErrorBuildInput {
  readonly stage: ErrorStage;
  readonly kind: ErrorKind;
  readonly message: string;
  readonly oldestFrameSeq: number;
  readonly newestFrameSeq: number;
  readonly frames: number;
  readonly audioBytes: number;
  readonly oldestAgeMs: number;
  readonly newestAgeMs: number;
  readonly flushLatenessMs: number;
  readonly inferenceElapsedMs: number | null;
  readonly inflightGatewayBatches: number;
  readonly gatewayBufferFrames: number;
  readonly inferenceStatus: number | null;
  readonly retryable: boolean;
}

export function parseStartMessage(text: string): ParseResult<{ type: "start" }> {
  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch (error) {
    return { success: false, message: errorMessage(error) };
  }

  const result = v.safeParse(StartMessageSchema, payload);
  if (!result.success) {
    return { success: false, message: result.issues.map((issue) => issue.message).join("; ") };
  }
  return { success: true, output: result.output };
}

export function parsePrediction(payload: unknown): Prediction {
  return v.parse(PredictionSchema, payload);
}

export function isPcmFrame(message: unknown): boolean {
  return toBytes(message)?.byteLength === FRAME_BYTES;
}

export function toBytes(message: unknown): Uint8Array | null {
  if (typeof message === "string") {
    return null;
  }
  if (message instanceof Uint8Array) {
    return message;
  }
  if (message instanceof ArrayBuffer) {
    return new Uint8Array(message);
  }
  return null;
}

export function buildPartialMessage(input: PartialBuildInput): string {
  return JSON.stringify({
    type: "partial",
    oldest_frame_seq: input.oldestFrameSeq,
    newest_frame_seq: input.newestFrameSeq,
    frames: input.frames,
    rms: input.prediction.rms,
    zero_crossings: input.prediction.zero_crossings,
    checksum: input.prediction.checksum,
    samples: input.prediction.samples,
    transcript: input.prediction.transcript,
    audio_bytes: input.prediction.audio_bytes,
    cpu_passes: input.cpuPasses,
    model_delay_ms: input.modelDelayMs,
    flush_lateness_ms: roundMillis(input.flushLatenessMs),
    inflight_model_jobs: 0,
  });
}

export function buildErrorMessage(input: ErrorBuildInput): string {
  return JSON.stringify({
    type: "error",
    stage: input.stage,
    kind: input.kind,
    message: input.message,
    oldest_frame_seq: input.oldestFrameSeq,
    newest_frame_seq: input.newestFrameSeq,
    frames: input.frames,
    audio_bytes: input.audioBytes,
    oldest_age_ms: roundMillis(input.oldestAgeMs),
    newest_age_ms: roundMillis(input.newestAgeMs),
    flush_lateness_ms: roundMillis(input.flushLatenessMs),
    inference_elapsed_ms:
      input.inferenceElapsedMs === null ? null : roundMillis(input.inferenceElapsedMs),
    inflight_gateway_batches: input.inflightGatewayBatches,
    gateway_buffer_frames: input.gatewayBufferFrames,
    inference_status: input.inferenceStatus,
    retryable: input.retryable,
  });
}

export function concatFrames(frames: Frame[]): Uint8Array {
  const totalBytes = frames.reduce((total, frame) => total + frame.payload.byteLength, 0);
  const body = new Uint8Array(totalBytes);
  let offset = 0;
  for (const frame of frames) {
    body.set(frame.payload, offset);
    offset += frame.payload.byteLength;
  }
  return body;
}

export function roundMillis(value: number): number {
  return Math.round(value * 1000) / 1000;
}

export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
