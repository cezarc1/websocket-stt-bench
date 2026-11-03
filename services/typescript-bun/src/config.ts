export const FRAME_BYTES = 640;
export const PARTIAL_CHANNEL_DEPTH = 4;

export const DEFAULT_CPU_PASSES = 4;
export const DEFAULT_MODEL_DELAY_MS = 75;
export const DEFAULT_FLUSH_INTERVAL_MS = 1000;
export const DEFAULT_FLUSH_PHASE_JITTER_MS = 0;
export const DEFAULT_INFERENCE_URL = "http://inference-server:9000";
export const DEFAULT_INFERENCE_TIMEOUT_MS = 2000;
export const DEFAULT_PORT = 7000;

const TRAILING_SLASHES = /\/+$/;

export interface SessionConfig {
  readonly cpuPasses: number;
  readonly modelDelayMs: number;
  readonly flushIntervalMs: number;
  readonly flushPhaseJitterMs: number;
  readonly inferenceTimeoutMs: number;
}

export interface AppConfig extends SessionConfig {
  readonly inferenceUrl: string;
  readonly port: number;
}

const FRAME_MS = 20;

/**
 * Per-session backlog cap, derived from the timeouts so it can never fire for
 * a session whose requests finish (even by timing out). Frames only pile up
 * while a flush waits: before the first flush (one interval plus the phase
 * jitter), or while the single in-flight request runs, which the inference
 * timeout bounds, plus up to one interval until the next tick takes them. The
 * longest healthy wait is therefore max(interval + jitter, timeout + interval)
 * = 3 s = 150 frames at the defaults; the cap is twice that (300 frames, 6 s,
 * ~190 KiB) so an event-loop stall of another full wait still passes. Only a
 * session whose flushes have stalled under sustained overload reaches it; it
 * is closed with 1013 instead of buffering until the process OOMs. Frames are
 * never dropped silently: the close tells the client the backlog was
 * abandoned.
 */
export function maxBufferedFrames(config: SessionConfig): number {
  const longestWaitMs = Math.max(
    config.flushIntervalMs + config.flushPhaseJitterMs,
    config.inferenceTimeoutMs + config.flushIntervalMs,
  );
  return 2 * Math.ceil(longestWaitMs / FRAME_MS);
}

export function loadConfig(env: Record<string, string | undefined> = process.env): AppConfig {
  return {
    cpuPasses: envInt(env, "CPU_PASSES", DEFAULT_CPU_PASSES),
    modelDelayMs: envInt(env, "MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS),
    flushIntervalMs: Math.max(1, envInt(env, "FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS)),
    flushPhaseJitterMs: envInt(env, "FLUSH_PHASE_JITTER_MS", DEFAULT_FLUSH_PHASE_JITTER_MS),
    inferenceUrl: (env.INFERENCE_URL ?? DEFAULT_INFERENCE_URL).replace(TRAILING_SLASHES, ""),
    inferenceTimeoutMs: Math.max(
      1,
      envInt(env, "INFERENCE_TIMEOUT_MS", DEFAULT_INFERENCE_TIMEOUT_MS),
    ),
    port: envInt(env, "PORT", DEFAULT_PORT),
  };
}

function envInt(
  env: Record<string, string | undefined>,
  name: string,
  defaultValue: number,
): number {
  const raw = env[name];
  if (raw === undefined || raw === "") {
    return defaultValue;
  }
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative integer`);
  }
  return parsed;
}
