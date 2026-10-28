import { afterAll, describe, expect, test } from "bun:test";

import { DEFAULT_INFERENCE_TIMEOUT_MS } from "../src/config.ts";
import { MAX_PAYLOAD_BYTES, startServer } from "../src/server.ts";

const server = startServer({
  cpuPasses: 4,
  modelDelayMs: 75,
  flushIntervalMs: 60_000,
  flushPhaseJitterMs: 0,
  inferenceUrl: "http://127.0.0.1:9",
  inferenceTimeoutMs: DEFAULT_INFERENCE_TIMEOUT_MS,
  port: 0,
});

afterAll(() => {
  void server.stop(true);
});

function closeCodeAfterFrame(size: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws/stt`);
    ws.binaryType = "arraybuffer";
    const timer = setTimeout(() => reject(new Error("no close within 2s")), 2000);
    ws.onopen = () => {
      ws.send(JSON.stringify({ type: "start" }));
      ws.send(new Uint8Array(size));
    };
    ws.onclose = (event) => {
      clearTimeout(timer);
      resolve(event.code);
    };
  });
}

describe("server frame-size cap", () => {
  test.each([
    0,
    10,
    639,
    641,
    8193,
    65_536,
    MAX_PAYLOAD_BYTES,
  ])("binary frame of %d bytes closes 1003", async (size) => {
    expect(await closeCodeAfterFrame(size)).toBe(1003);
  });

  test("frames above the cap are dropped by Bun, not closed 1003", async () => {
    // Documents the limit in server.ts: uWebSockets drops the socket (1006).
    expect(await closeCodeAfterFrame(MAX_PAYLOAD_BYTES + 1)).toBe(1006);
  });
});
