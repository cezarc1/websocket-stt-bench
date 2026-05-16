export const FRAME_BYTES = 640;
export const PARTIAL_CHANNEL_DEPTH = 4;

export const DEFAULT_CPU_PASSES = 4;
export const DEFAULT_MODEL_DELAY_MS = 75;
export const DEFAULT_FLUSH_INTERVAL_MS = 1000;
export const DEFAULT_FLUSH_PHASE_JITTER_MS = 0;
export const DEFAULT_INFERENCE_URL = "http://inference-server:9000";
export const DEFAULT_INFERENCE_TIMEOUT_MS = 2000;
export const DEFAULT_PORT = 7000;

export interface SessionConfig {
  readonly cpuPasses: number;
  readonly modelDelayMs: number;
  readonly flushIntervalMs: number;
  readonly flushPhaseJitterMs: number;
}

export interface AppConfig extends SessionConfig {
  readonly inferenceUrl: string;
  readonly inferenceTimeoutMs: number;
  readonly port: number;
}

export function loadConfig(env: Record<string, string | undefined> = process.env): AppConfig {
  return {
    cpuPasses: envInt(env, "CPU_PASSES", DEFAULT_CPU_PASSES),
    modelDelayMs: envInt(env, "MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS),
    flushIntervalMs: Math.max(1, envInt(env, "FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS)),
    flushPhaseJitterMs: envInt(env, "FLUSH_PHASE_JITTER_MS", DEFAULT_FLUSH_PHASE_JITTER_MS),
    inferenceUrl: (env.INFERENCE_URL ?? DEFAULT_INFERENCE_URL).replace(/\/+$/, ""),
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
