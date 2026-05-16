import { describe, expect, test } from "bun:test";

import { InferenceError, runInference } from "../src/inference.ts";

describe("runInference", () => {
  test("matches Python parse-error diagnostics with null inference_status", async () => {
    const fetchImpl = Object.assign(
      async () =>
        new Response(JSON.stringify({ transcript: "missing numeric fields" }), {
          status: 200,
        }),
      { preconnect: () => {} },
    ) as typeof fetch;

    await expect(
      runInference(fetchImpl, "http://inference.example/infer", 2000, new Uint8Array([1]), 4),
    ).rejects.toMatchObject({
      constructor: InferenceError,
      stage: "inference_response_parse",
      kind: "parse_error",
      inferenceStatus: null,
      retryable: false,
    });
  });
});
