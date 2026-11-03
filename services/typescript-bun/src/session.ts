import {
  DEFAULT_CPU_PASSES,
  DEFAULT_FLUSH_INTERVAL_MS,
  DEFAULT_FLUSH_PHASE_JITTER_MS,
  DEFAULT_INFERENCE_TIMEOUT_MS,
  DEFAULT_MODEL_DELAY_MS,
  PARTIAL_CHANNEL_DEPTH,
  type SessionConfig,
  maxBufferedFrames,
} from "./config.ts";
import { InferenceError, type InferenceRunner } from "./inference.ts";
import {
  CLOSE_INTERNAL_ERROR,
  CLOSE_PROTOCOL_ERROR,
  CLOSE_TRY_AGAIN_LATER,
  CLOSE_UNSUPPORTED_DATA,
  FRAME_BYTES,
  REASON_BACKLOG_EXCEEDED,
  REASON_BAD_FRAME_SIZE,
  REASON_NEED_START,
  REASON_SEND_DROPPED,
  REASON_TEXT_AFTER_START,
  buildErrorMessage,
  buildPartialMessage,
  concatFrames,
  errorMessage,
  parseStartMessage,
  toBytes,
  type Frame,
} from "./protocol.ts";

export interface SocketLike {
  send(message: string): number;
  close(code?: number, reason?: string): void;
  getBufferedAmount?(): number;
}

export interface SttSessionOptions extends Partial<SessionConfig> {
  inference: InferenceRunner;
  timers?: boolean;
}

type TimerHandle = ReturnType<typeof setTimeout>;

interface Batch {
  readonly oldestSeq: number;
  readonly newestSeq: number;
  readonly frames: number;
  readonly oldestReceivedAtMs: number;
  readonly newestReceivedAtMs: number;
  readonly body: Uint8Array;
}

export class SttSession {
  private readonly socket: SocketLike;
  private readonly inference: InferenceRunner;
  private readonly config: SessionConfig;
  private readonly outbox: BoundedOutbox;
  private readonly timers: boolean;
  private readonly maxBufferedFrames: number;
  private readonly buffer: Frame[] = [];
  private seq = 0;
  private started = false;
  private closed = false;
  private timer: TimerHandle | null = null;
  private nextDueMs = 0;
  private inflight: Promise<void> | null = null;
  private inflightAbort: AbortController | null = null;

  public constructor(socket: SocketLike, options: SttSessionOptions) {
    this.socket = socket;
    this.inference = options.inference;
    this.config = {
      cpuPasses: options.cpuPasses ?? DEFAULT_CPU_PASSES,
      modelDelayMs: options.modelDelayMs ?? DEFAULT_MODEL_DELAY_MS,
      flushIntervalMs: Math.max(1, options.flushIntervalMs ?? DEFAULT_FLUSH_INTERVAL_MS),
      flushPhaseJitterMs: options.flushPhaseJitterMs ?? DEFAULT_FLUSH_PHASE_JITTER_MS,
      inferenceTimeoutMs: options.inferenceTimeoutMs ?? DEFAULT_INFERENCE_TIMEOUT_MS,
    };
    this.maxBufferedFrames = maxBufferedFrames(this.config);
    this.outbox = new BoundedOutbox(socket, PARTIAL_CHANNEL_DEPTH);
    this.timers = options.timers ?? true;
  }

  public handleMessage(message: string | ArrayBuffer | Uint8Array): void {
    if (this.closed) {
      return;
    }

    if (!this.started) {
      if (typeof message !== "string" || !parseStartMessage(message).success) {
        this.closeWith(CLOSE_PROTOCOL_ERROR, REASON_NEED_START);
        return;
      }
      this.started = true;
      if (this.timers) {
        this.startFlushLoop();
      }
      return;
    }

    const bytes = toBytes(message);
    if (bytes === null) {
      this.closeWith(CLOSE_PROTOCOL_ERROR, REASON_TEXT_AFTER_START);
      return;
    }
    if (bytes.byteLength !== FRAME_BYTES) {
      this.closeWith(CLOSE_UNSUPPORTED_DATA, REASON_BAD_FRAME_SIZE);
      return;
    }

    if (this.buffer.length >= this.maxBufferedFrames) {
      this.closeWith(CLOSE_TRY_AGAIN_LATER, REASON_BACKLOG_EXCEEDED);
      return;
    }
    this.seq += 1;
    // Kept without a copy: Bun hands every message its own fresh buffer
    // (never a view into a reused receive buffer), and a second copy per frame
    // doubled the allocation rate and peak memory under overload.
    this.buffer.push({ seq: this.seq, payload: bytes, receivedAtMs: performance.now() });
  }

  public drain(): void {
    this.outbox.drain();
  }

  public close(): void {
    this.closed = true;
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.inflightAbort?.abort();
    this.outbox.close();
  }

  /** @internal Test-only — do not call from production code. */
  public flushOnceForTest(flushLatenessMs: number): Promise<void> {
    return this.flushDue(flushLatenessMs);
  }

  /** @internal Test-only — do not call from production code. */
  public maxBufferedFramesForTest(): number {
    return this.maxBufferedFrames;
  }

  /** @internal Test-only — do not call from production code. */
  public bufferedFramesForTest(): number {
    return this.buffer.length;
  }

  private closeWith(code: number, reason: string): void {
    this.close();
    this.socket.close(code, reason);
  }

  private startFlushLoop(): void {
    this.nextDueMs =
      performance.now() +
      this.config.flushIntervalMs +
      Math.random() * this.config.flushPhaseJitterMs;
    this.scheduleNextFlush();
  }

  private scheduleNextFlush(): void {
    if (this.closed) {
      return;
    }
    this.timer = setTimeout(
      () => {
        const nowMs = performance.now();
        const flushLatenessMs = Math.max(0, nowMs - this.nextDueMs);
        this.nextDueMs += this.config.flushIntervalMs;
        this.scheduleNextFlush();
        void this.flushDue(flushLatenessMs);
      },
      Math.max(0, this.nextDueMs - performance.now()),
    );
  }

  private flushDue(flushLatenessMs: number): Promise<void> {
    if (this.inflight !== null || this.buffer.length === 0 || this.closed) {
      return Promise.resolve();
    }

    const frames = this.buffer.splice(0, this.buffer.length);
    const oldest = frames[0];
    const newest = frames[frames.length - 1];
    if (oldest === undefined || newest === undefined) {
      return Promise.resolve();
    }
    // Only the concatenated body and the edge frames' metadata outlive this
    // call: the frame array becomes garbage now instead of being pinned (with
    // a second copy of the same audio) until the request finishes.
    const batch: Batch = {
      oldestSeq: oldest.seq,
      newestSeq: newest.seq,
      frames: frames.length,
      oldestReceivedAtMs: oldest.receivedAtMs,
      newestReceivedAtMs: newest.receivedAtMs,
      body: concatFrames(frames),
    };
    const task = this.processBatch(batch, flushLatenessMs).finally(() => {
      if (this.inflight === task) {
        this.inflight = null;
        this.inflightAbort = null;
      }
    });
    this.inflight = task;
    return task;
  }

  private async processBatch(batch: Batch, flushLatenessMs: number): Promise<void> {
    const { body } = batch;
    const startedAtMs = performance.now();
    const abort = new AbortController();
    this.inflightAbort = abort;

    try {
      const prediction = await this.inference(body, this.config.cpuPasses, abort.signal);
      if (!this.closed) {
        await this.outbox.enqueue(
          buildPartialMessage({
            oldestFrameSeq: batch.oldestSeq,
            newestFrameSeq: batch.newestSeq,
            frames: batch.frames,
            prediction,
            cpuPasses: this.config.cpuPasses,
            modelDelayMs: this.config.modelDelayMs,
            flushLatenessMs,
          }),
        );
      }
    } catch (error) {
      if (this.closed) {
        return;
      }
      const details =
        error instanceof InferenceError
          ? error
          : new InferenceError({
              stage: "inference_request",
              kind: "connection_reset",
              message: errorMessage(error),
              inferenceStatus: null,
              retryable: true,
            });
      const nowMs = performance.now();
      await this.outbox.enqueue(
        buildErrorMessage({
          stage: details.stage,
          kind: details.kind,
          message: details.message,
          oldestFrameSeq: batch.oldestSeq,
          newestFrameSeq: batch.newestSeq,
          frames: batch.frames,
          audioBytes: body.byteLength,
          oldestAgeMs: nowMs - batch.oldestReceivedAtMs,
          newestAgeMs: nowMs - batch.newestReceivedAtMs,
          flushLatenessMs,
          inferenceElapsedMs: nowMs - startedAtMs,
          inflightGatewayBatches: 1,
          gatewayBufferFrames: this.buffer.length,
          inferenceStatus: details.inferenceStatus,
          retryable: details.retryable,
        }),
      );
    }
  }
}

export class BoundedOutbox {
  private readonly socket: SocketLike;
  private readonly depth: number;
  private readonly queue: string[] = [];
  private readonly waiters: Array<() => void> = [];
  private closed = false;
  private pendingBackpressure = 0;

  public constructor(socket: SocketLike, depth: number) {
    this.socket = socket;
    this.depth = depth;
  }

  public async enqueue(message: string): Promise<void> {
    while (!this.closed && this.occupiedSlots() >= this.depth) {
      // Intentionally sequential: each wake re-checks capacity before enqueueing.
      // biome-ignore lint/performance/noAwaitInLoops: back-pressure waiter loop
      await new Promise<void>((resolve) => this.waiters.push(resolve)); // oxlint-disable-line no-await-in-loop
    }
    if (this.closed) {
      return;
    }
    this.queue.push(message);
    this.drain();
  }

  public drain(): void {
    if (this.closed) {
      return;
    }
    if (this.pendingBackpressure > 0) {
      if ((this.socket.getBufferedAmount?.() ?? 0) > 0) {
        return;
      }
      // The send loop below returns as soon as ws.send() reports -1, so
      // pendingBackpressure is always 0 or 1 here; unconditional clear
      // is correct under that invariant.
      this.pendingBackpressure = 0;
      this.resolveSpace();
    }
    while (this.queue.length > 0) {
      const next = this.queue[0];
      if (next === undefined) {
        return;
      }
      const status = this.socket.send(next);
      if (status === 0) {
        // Bun dropped the message. Continuing would leave a silent seq gap
        // for the client, so end the connection explicitly instead; Bun's
        // close handler then tears the session down.
        this.close();
        this.socket.close(CLOSE_INTERNAL_ERROR, REASON_SEND_DROPPED);
        return;
      }
      this.queue.shift();
      if (status < 0) {
        this.pendingBackpressure = 1;
        this.resolveSpace();
        return;
      }
      this.resolveSpace();
    }
  }

  public close(): void {
    this.closed = true;
    this.queue.length = 0;
    this.pendingBackpressure = 0;
    while (this.waiters.length > 0) {
      this.waiters.shift()?.();
    }
  }

  private occupiedSlots(): number {
    return this.queue.length + this.pendingBackpressure;
  }

  private resolveSpace(): void {
    this.waiters.shift()?.();
  }
}
