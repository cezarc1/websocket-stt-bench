import {
  errorMessage,
  parsePrediction,
  type ErrorKind,
  type ErrorStage,
  type Prediction,
} from "./protocol.ts";

export type InferenceRunner = (
  body: Uint8Array,
  cpuPasses: number,
  signal?: AbortSignal,
) => Promise<Prediction>;

export interface InferenceErrorDetails {
  readonly stage: ErrorStage;
  readonly kind: ErrorKind;
  readonly message: string;
  readonly inferenceStatus: number | null;
  readonly retryable: boolean;
}

export class InferenceError extends Error implements InferenceErrorDetails {
  public readonly stage: ErrorStage;
  public readonly kind: ErrorKind;
  public readonly inferenceStatus: number | null;
  public readonly retryable: boolean;

  public constructor(details: InferenceErrorDetails) {
    super(details.message);
    this.name = "InferenceError";
    this.stage = details.stage;
    this.kind = details.kind;
    this.inferenceStatus = details.inferenceStatus;
    this.retryable = details.retryable;
  }
}

// Bun.fetch uses HTTP/1.1 with keep-alive connection pooling (sized by
// BUN_CONFIG_MAX_HTTP_REQUESTS). This matches the Python gateway's aiohttp
// client; the Rust gateway is the outlier with reqwest's
// http2_prior_knowledge(). Keeping HTTP/1.1 here makes the TS-vs-Python
// comparison apples-to-apples.
export function createInferenceRunner(
  baseUrl: string,
  timeoutMs: number,
  fetchImpl: typeof fetch = fetch,
): InferenceRunner {
  const url = `${baseUrl}/infer`;
  return (body, cpuPasses, signal) =>
    runInference(fetchImpl, url, timeoutMs, body, cpuPasses, signal);
}

export async function runInference(
  fetchImpl: typeof fetch,
  url: string,
  timeoutMs: number,
  body: Uint8Array,
  cpuPasses: number,
  signal?: AbortSignal,
): Promise<Prediction> {
  const timeoutSignal = AbortSignal.timeout(timeoutMs);

  let response: Response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: { "x-cpu-passes": String(cpuPasses) },
      body,
      signal: signal === undefined ? timeoutSignal : AbortSignal.any([signal, timeoutSignal]),
    });
  } catch (error) {
    throw classifyFetchError(error);
  }

  if (!response.ok) {
    throw new InferenceError({
      stage: "inference_request",
      kind: classifyStatus(response.status),
      message: `inference returned status ${response.status}`,
      inferenceStatus: response.status,
      retryable: response.status === 429 || response.status >= 500,
    });
  }

  try {
    return parsePrediction(await response.json());
  } catch (error) {
    throw new InferenceError({
      stage: "inference_response_parse",
      kind: "parse_error",
      message: errorMessage(error),
      inferenceStatus: null,
      retryable: false,
    });
  }
}

function classifyStatus(status: number): ErrorKind {
  if (status === 429) {
    return "http_429";
  }
  return "http_5xx";
}

function classifyFetchError(error: unknown): InferenceError {
  const message = errorMessage(error);
  if (error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError")) {
    return new InferenceError({
      stage: "inference_request",
      kind: "timeout",
      message: message || error.name,
      inferenceStatus: null,
      retryable: true,
    });
  }
  return new InferenceError({
    stage: "inference_request",
    kind: "connection_reset",
    message,
    inferenceStatus: null,
    retryable: true,
  });
}
