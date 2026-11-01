import { describe, expect, test } from "bun:test";

import { InferenceError, type InferenceRunner } from "../src/inference.ts";
import { BoundedOutbox, SttSession, type SocketLike } from "../src/session.ts";
import {
  DEFAULT_FLUSH_INTERVAL_MS,
  DEFAULT_INFERENCE_TIMEOUT_MS,
  maxBufferedFrames,
} from "../src/config.ts";
import { FRAME_BYTES } from "../src/protocol.ts";

class FakeSocket implements SocketLike {
  public sent: string[] = [];
  public closes: Array<{ code?: number; reason?: string }> = [];
  public bufferedAmount = 0;
  public nextSendStatus: number | null = null;

  send(message: string): number {
    this.sent.push(message);
    return this.nextSendStatus ?? message.length;
  }

  close(code?: number, reason?: string): void {
    this.closes.push({ code, reason });
  }

  getBufferedAmount(): number {
    return this.bufferedAmount;
  }
}

function frame(fill: number): Uint8Array {
  return new Uint8Array(FRAME_BYTES).fill(fill);
}

function deferred<T>(): {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
} {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((innerResolve, innerReject) => {
    resolve = innerResolve;
    reject = innerReject;
  });
  return { promise, resolve, reject };
}

function prediction(audioBytes: number): Awaited<ReturnType<InferenceRunner>> {
  return {
    rms: 1,
    zero_crossings: 1,
    checksum: 1,
    samples: audioBytes / 2,
    transcript: "now",
    audio_bytes: audioBytes,
  };
}

function unexpectedInference(): Promise<never> {
  return Promise.reject(new Error("unexpected"));
}

describe("SttSession", () => {
  test("closes with 1002 when the first message is not start", () => {
    const socket = new FakeSocket();
    const session = new SttSession(socket, {
      inference: async () => {
        throw new Error("unexpected");
      },
      timers: false,
    });

    session.handleMessage("not-json");

    expect(socket.closes).toEqual([{ code: 1002, reason: "first message must be start" }]);
  });

  test("closes with 1003 when a binary frame has the wrong size", () => {
    const socket = new FakeSocket();
    const session = new SttSession(socket, {
      inference: async () => {
        throw new Error("unexpected");
      },
      timers: false,
    });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(new Uint8Array(10));

    expect(socket.closes).toEqual([{ code: 1003, reason: "expected 640 byte PCM frame" }]);
  });

  test("flushes one batch into an exact partial message", async () => {
    const socket = new FakeSocket();
    const inference: InferenceRunner = async (_body, cpuPasses) => {
      expect(cpuPasses).toBe(4);
      return {
        rms: 1.5,
        zero_crossings: 2,
        checksum: 3,
        samples: 1280,
        transcript: "now",
        audio_bytes: 1280,
      };
    };
    const session = new SttSession(socket, { inference, timers: false });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(1));
    session.handleMessage(frame(2));
    await session.flushOnceForTest(2.34567);

    expect(socket.sent).toHaveLength(1);
    expect(JSON.parse(socket.sent[0])).toMatchObject({
      type: "partial",
      oldest_frame_seq: 1,
      newest_frame_seq: 2,
      frames: 2,
      audio_bytes: 1280,
      flush_lateness_ms: 2.346,
      inflight_model_jobs: 0,
    });
  });

  test("preserves buffered frames when a flush is already in flight", async () => {
    const socket = new FakeSocket();
    const gate = deferred<Awaited<ReturnType<InferenceRunner>>>();
    const session = new SttSession(socket, {
      inference: () => gate.promise,
      timers: false,
    });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(1));
    const firstFlush = session.flushOnceForTest(0);
    session.handleMessage(frame(2));

    await session.flushOnceForTest(0);
    expect(session.bufferedFramesForTest()).toBe(1);
    expect(socket.sent).toHaveLength(0);

    gate.resolve({
      rms: 1,
      zero_crossings: 1,
      checksum: 1,
      samples: 640,
      transcript: "now",
      audio_bytes: 640,
    });
    await firstFlush;

    expect(socket.sent).toHaveLength(1);
    expect(session.bufferedFramesForTest()).toBe(1);
  });

  test("closes with 1013 once a stalled session's backlog hits the cap", async () => {
    const socket = new FakeSocket();
    const gate = deferred<Awaited<ReturnType<InferenceRunner>>>();
    const session = new SttSession(socket, {
      inference: () => gate.promise,
      timers: false,
    });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(0));
    // The single in-flight request never completes, so every later flush is
    // skipped and frames pile up.
    const stalled = session.flushOnceForTest(0);
    const cap = session.maxBufferedFramesForTest();
    for (let i = 0; i < cap; i += 1) {
      session.handleMessage(frame(1));
    }
    await session.flushOnceForTest(0);
    expect(session.bufferedFramesForTest()).toBe(cap);
    expect(socket.closes).toHaveLength(0);

    session.handleMessage(frame(2));
    expect(socket.closes).toEqual([
      { code: 1013, reason: "gateway overloaded: frame backlog limit exceeded" },
    ]);
    // Closed sessions ignore further input instead of growing again.
    session.handleMessage(frame(3));
    expect(socket.closes).toHaveLength(1);

    gate.resolve(prediction(FRAME_BYTES));
    await stalled;
    expect(socket.sent).toHaveLength(0);
  });

  test("the backlog cap is twice the longest wait a healthy flush can see", () => {
    const base = {
      cpuPasses: 4,
      modelDelayMs: 75,
      flushIntervalMs: 1000,
      flushPhaseJitterMs: 0,
      inferenceTimeoutMs: 2000,
    };
    // (2 s timeout + 1 s until the next tick) = 150 frames, doubled.
    expect(maxBufferedFrames(base)).toBe(300);
    // The phase jitter only delays the first flush, when nothing is in flight.
    expect(maxBufferedFrames({ ...base, flushPhaseJitterMs: 1000 })).toBe(300);
    expect(maxBufferedFrames({ ...base, flushPhaseJitterMs: 5000 })).toBe(600);
    expect(maxBufferedFrames({ ...base, inferenceTimeoutMs: 5000 })).toBe(600);
  });

  test("a session whose every request runs to the inference timeout never hits the cap", async () => {
    const socket = new FakeSocket();
    let gate = deferred<Awaited<ReturnType<InferenceRunner>>>();
    const session = new SttSession(socket, { inference: () => gate.promise, timers: false });
    // Frames that arrive while one request runs for the whole timeout, plus
    // one interval until the next tick picks them up.
    const framesPerCycle = (DEFAULT_INFERENCE_TIMEOUT_MS + DEFAULT_FLUSH_INTERVAL_MS) / 20;

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(0));
    for (let cycle = 0; cycle < 10; cycle += 1) {
      const pending = session.flushOnceForTest(0);
      for (let i = 0; i < framesPerCycle; i += 1) {
        session.handleMessage(frame(cycle));
      }
      gate.resolve(prediction(FRAME_BYTES));
      // Sequential by design: one in-flight request per session.
      // biome-ignore lint/performance/noAwaitInLoops: one request at a time
      await pending; // oxlint-disable-line no-await-in-loop
      gate = deferred();
    }

    expect(socket.closes).toHaveLength(0);
    expect(session.bufferedFramesForTest()).toBe(framesPerCycle);
  });

  test("a session that flushes every interval never approaches the backlog cap", async () => {
    const socket = new FakeSocket();
    const session = new SttSession(socket, {
      inference: (body) => Promise.resolve(prediction(body.byteLength)),
      timers: false,
    });

    session.handleMessage('{"type":"start"}');
    // 60 s of audio, flushed once per 50 frames (one 1000 ms interval).
    for (let second = 0; second < 60; second += 1) {
      for (let i = 0; i < 50; i += 1) {
        session.handleMessage(frame(second));
      }
      // Sequential by design: each flush must finish before the next interval.
      // biome-ignore lint/performance/noAwaitInLoops: one flush per interval
      await session.flushOnceForTest(0); // oxlint-disable-line no-await-in-loop
    }

    expect(socket.closes).toHaveLength(0);
    expect(socket.sent).toHaveLength(60);
  });

  test("relays inference timeouts as error messages on the wire", async () => {
    const socket = new FakeSocket();
    const inference: InferenceRunner = async () => {
      throw new InferenceError({
        stage: "inference_request",
        kind: "timeout",
        message: "timed out after 2000 ms",
        inferenceStatus: null,
        retryable: true,
      });
    };
    const session = new SttSession(socket, { inference, timers: false });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(1));
    await session.flushOnceForTest(0);

    expect(socket.sent).toHaveLength(1);
    expect(JSON.parse(socket.sent[0])).toMatchObject({
      type: "error",
      stage: "inference_request",
      kind: "timeout",
      oldest_frame_seq: 1,
      newest_frame_seq: 1,
      frames: 1,
      audio_bytes: FRAME_BYTES,
      inference_status: null,
      retryable: true,
    });
  });

  test.each([
    ["non-JSON text", "not-json"],
    ["wrong type", '{"type":"stop"}'],
    ["binary frame before start", new Uint8Array(FRAME_BYTES)],
  ])("closes with 1002 on invalid first message: %s", (_label, first) => {
    const socket = new FakeSocket();
    const session = new SttSession(socket, { inference: unexpectedInference, timers: false });

    session.handleMessage(first);
    session.handleMessage('{"type":"start"}');

    expect(socket.closes).toEqual([{ code: 1002, reason: "first message must be start" }]);
  });

  test.each([
    0,
    10,
    FRAME_BYTES - 1,
    FRAME_BYTES + 1,
  ])("closes with 1003 on a %i byte binary frame and drops the buffered batch", async (size) => {
    const socket = new FakeSocket();
    const session = new SttSession(socket, { inference: unexpectedInference, timers: false });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(1));
    session.handleMessage(new Uint8Array(size));
    await session.flushOnceForTest(0);

    expect(socket.closes).toEqual([{ code: 1003, reason: "expected 640 byte PCM frame" }]);
    expect(socket.sent).toHaveLength(0);
  });

  test("tiles seq ranges across partials and error frames with frames sent in order", async () => {
    const socket = new FakeSocket();
    const bodies: Uint8Array[] = [];
    let call = 0;
    const inference: InferenceRunner = async (body) => {
      bodies.push(body.slice());
      call += 1;
      if (call === 2) {
        throw new Error("connection reset");
      }
      return prediction(body.byteLength);
    };
    const session = new SttSession(socket, { inference, timers: false });

    session.handleMessage('{"type":"start"}');
    let fill = 0;
    for (const batchSize of [2, 3, 1]) {
      for (let i = 0; i < batchSize; i++) {
        fill += 1;
        session.handleMessage(frame(fill));
      }
      // biome-ignore lint/performance/noAwaitInLoops: each flush must finish before the next batch
      await session.flushOnceForTest(0); // oxlint-disable-line no-await-in-loop
    }

    const messages = socket.sent.map((m) => JSON.parse(m));
    expect(messages.map((m) => [m.type, m.oldest_frame_seq, m.newest_frame_seq, m.frames])).toEqual(
      [
        ["partial", 1, 2, 2],
        ["error", 3, 5, 3],
        ["partial", 6, 6, 1],
      ],
    );
    expect(messages.map((m) => m.audio_bytes)).toEqual([2, 3, 1].map((n) => n * FRAME_BYTES));
    expect(bodies.map((b) => [...new Set(b)])).toEqual([[1, 2], [3, 4, 5], [6]]);
    for (const body of bodies) {
      for (let i = 0; i < body.byteLength; i += FRAME_BYTES) {
        expect(body.subarray(i, i + FRAME_BYTES).every((byte) => byte === body[i])).toBe(true);
      }
    }
  });

  test("timer-driven flushes never overlap an in-flight inference request", async () => {
    const socket = new FakeSocket();
    let active = 0;
    let maxActive = 0;
    let calls = 0;
    const inference: InferenceRunner = async (body) => {
      active += 1;
      calls += 1;
      maxActive = Math.max(maxActive, active);
      await Bun.sleep(25);
      active -= 1;
      return prediction(body.byteLength);
    };
    const session = new SttSession(socket, { inference, flushIntervalMs: 2 });

    session.handleMessage('{"type":"start"}');
    for (let i = 1; i <= 20; i++) {
      session.handleMessage(frame(i));
      // biome-ignore lint/performance/noAwaitInLoops: paced frame stream
      await Bun.sleep(3); // oxlint-disable-line no-await-in-loop
    }
    await Bun.sleep(60);
    session.close();

    expect(calls).toBeGreaterThan(1);
    expect(maxActive).toBe(1);
    const ranges = socket.sent.map((m) => JSON.parse(m));
    let prevNewest = 0;
    for (const m of ranges) {
      expect(m.oldest_frame_seq).toBe(prevNewest + 1);
      prevNewest = m.newest_frame_seq;
    }
    expect(prevNewest).toBe(20);
  });

  test("aborts inflight inference on close and drops the would-be partial", async () => {
    const socket = new FakeSocket();
    const gate = deferred<Awaited<ReturnType<InferenceRunner>>>();
    let abortedDuringRun = false;
    const inference: InferenceRunner = async (_body, _passes, signal) => {
      signal?.addEventListener("abort", () => {
        abortedDuringRun = true;
        gate.reject(new Error("aborted"));
      });
      return gate.promise;
    };
    const session = new SttSession(socket, { inference, timers: false });

    session.handleMessage('{"type":"start"}');
    session.handleMessage(frame(1));
    const flush = session.flushOnceForTest(0);
    session.close();

    await flush;
    expect(abortedDuringRun).toBe(true);
    expect(socket.sent).toHaveLength(0);
  });
});

describe("BoundedOutbox", () => {
  test("drains queued messages straight to the socket without buffering when no backpressure", async () => {
    const socket = new FakeSocket();
    const outbox = new BoundedOutbox(socket, 4);

    await outbox.enqueue("one");
    await outbox.enqueue("two");
    await outbox.enqueue("three");

    expect(socket.sent).toEqual(["one", "two", "three"]);
  });

  test("counts Bun internal backpressure against the application outbox depth", async () => {
    const socket = new FakeSocket();
    socket.nextSendStatus = -1;
    socket.bufferedAmount = 10;
    const outbox = new BoundedOutbox(socket, 4);

    await outbox.enqueue("one");
    const second = outbox.enqueue("two");
    const third = outbox.enqueue("three");
    const fourth = outbox.enqueue("four");
    let fifthDone = false;
    const fifth = outbox.enqueue("five").then(() => {
      fifthDone = true;
    });

    await Promise.resolve();

    expect(fifthDone).toBe(false);
    expect(socket.sent).toEqual(["one"]);

    socket.nextSendStatus = null;
    socket.bufferedAmount = 0;
    outbox.drain();
    await Promise.all([second, third, fourth, fifth]);

    expect(fifthDone).toBe(true);
    expect(socket.sent).toEqual(["one", "two", "three", "four", "five"]);
  });

  test("closes the socket with 1011 instead of silently dropping when Bun drops a send", async () => {
    const socket = new FakeSocket();
    socket.nextSendStatus = 0;
    const outbox = new BoundedOutbox(socket, 4);

    await outbox.enqueue("one");
    socket.nextSendStatus = null;
    await outbox.enqueue("two");

    expect(socket.sent).toEqual(["one"]);
    expect(socket.closes).toEqual([{ code: 1011, reason: "outbound message dropped" }]);
  });
});
