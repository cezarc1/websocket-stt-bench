import { describe, expect, test } from "bun:test";

import { InferenceError, type InferenceRunner } from "../src/inference.ts";
import { BoundedOutbox, SttSession, type SocketLike } from "../src/session.ts";
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
});
