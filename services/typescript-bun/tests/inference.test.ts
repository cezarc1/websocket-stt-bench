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

  // Bun 1.3.13 resolves the body of a fetch whose AbortSignal fired after the
  // headers arrived as "" (seen under event-loop lag past the timeout). That
  // is a timeout, not malformed JSON from the inference server.
  test("classifies an empty body after the timeout fired as a timeout", async () => {
    const fetchImpl = Object.assign(
      async (_url: string, init: RequestInit) => {
        const signal = init.signal as AbortSignal;
        await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
        return new Response("", { status: 200, headers: { "content-length": "126" } });
      },
      { preconnect: () => {} },
    ) as unknown as typeof fetch;

    await expect(
      runInference(fetchImpl, "http://inference.example/infer", 5, new Uint8Array([1]), 4),
    ).rejects.toMatchObject({
      constructor: InferenceError,
      stage: "inference_request",
      kind: "timeout",
      retryable: true,
    });
  });

  test("classifies a body cut off by a dropped connection as connection_reset", async () => {
    const fetchImpl = Object.assign(
      async () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new TextEncoder().encode('{"rms":'));
              controller.error(
                Object.assign(new Error("The socket connection was closed unexpectedly."), {
                  code: "ECONNRESET",
                }),
              );
            },
          }),
          { status: 200 },
        ),
      { preconnect: () => {} },
    ) as typeof fetch;

    await expect(
      runInference(fetchImpl, "http://inference.example/infer", 2000, new Uint8Array([1]), 4),
    ).rejects.toMatchObject({
      constructor: InferenceError,
      stage: "inference_request",
      kind: "connection_reset",
      retryable: true,
    });
  });

  test("classifies a real server body that misses the deadline as a timeout", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: () =>
        new Response(
          new ReadableStream({
            async start(controller) {
              controller.enqueue(new TextEncoder().encode('{"rms":'));
              await Bun.sleep(200);
              controller.enqueue(new TextEncoder().encode("1}"));
              controller.close();
            },
          }),
          { headers: { "content-type": "application/json" } },
        ),
    });
    try {
      await expect(
        runInference(fetch, `http://127.0.0.1:${server.port}/infer`, 50, new Uint8Array([1]), 4),
      ).rejects.toMatchObject({
        constructor: InferenceError,
        stage: "inference_request",
        kind: "timeout",
      });
    } finally {
      await server.stop(true);
    }
  });
});
