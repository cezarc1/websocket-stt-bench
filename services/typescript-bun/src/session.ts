import {
  DEFAULT_CPU_PASSES,
  DEFAULT_FLUSH_INTERVAL_MS,
  DEFAULT_FLUSH_PHASE_JITTER_MS,
  DEFAULT_MODEL_DELAY_MS,
  PARTIAL_CHANNEL_DEPTH,
  type SessionConfig,
} from "./config.ts";
import { InferenceError, type InferenceRunner } from "./inference.ts";
import {
  CLOSE_PROTOCOL_ERROR,
  CLOSE_UNSUPPORTED_DATA,
  FRAME_BYTES,
  REASON_BAD_FRAME_SIZE,
  REASON_NEED_START,
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

export class SttSession {
  private readonly socket: SocketLike;
  private readonly inference: InferenceRunner;
  private readonly config: SessionConfig;
  private readonly outbox: BoundedOutbox;
  private readonly timers: boolean;
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
    };
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

    this.seq += 1;
    this.buffer.push({
      seq: this.seq,
      payload: new Uint8Array(bytes),
      receivedAtMs: performance.now(),
    });
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

    const batch = this.buffer.splice(0, this.buffer.length);
    const task = this.processBatch(batch, flushLatenessMs).finally(() => {
      if (this.inflight === task) {
        this.inflight = null;
        this.inflightAbort = null;
      }
    });
    this.inflight = task;
    return task;
  }

  private async processBatch(batch: Frame[], flushLatenessMs: number): Promise<void> {
    const oldest = batch[0];
    const newest = batch[batch.length - 1];
    if (oldest === undefined || newest === undefined) {
      return;
    }

    const body = concatFrames(batch);
    const startedAtMs = performance.now();
    const abort = new AbortController();
    this.inflightAbort = abort;

    try {
      const prediction = await this.inference(body, this.config.cpuPasses, abort.signal);
      if (!this.closed) {
        await this.outbox.enqueue(
          buildPartialMessage({
            oldestFrameSeq: oldest.seq,
            newestFrameSeq: newest.seq,
            frames: batch.length,
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
          oldestFrameSeq: oldest.seq,
          newestFrameSeq: newest.seq,
          frames: batch.length,
          audioBytes: body.byteLength,
          oldestAgeMs: nowMs - oldest.receivedAtMs,
          newestAgeMs: nowMs - newest.receivedAtMs,
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
      await new Promise<void>((resolve) => this.waiters.push(resolve));
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
        this.close();
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
