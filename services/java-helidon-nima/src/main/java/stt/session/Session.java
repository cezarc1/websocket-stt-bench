package stt.session;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.ObjectWriter;
import io.helidon.common.buffers.BufferData;
import io.helidon.websocket.WsListener;
import io.helidon.websocket.WsSession;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.LockSupport;
import java.util.logging.Level;
import java.util.logging.Logger;
import org.jspecify.annotations.Nullable;
import stt.config.Config;
import stt.inference.Inference;
import stt.inference.InferenceException;
import stt.protocol.ErrorMessage;
import stt.protocol.Frame;
import stt.protocol.OutboundMessage;
import stt.protocol.PartialMessage;
import stt.protocol.Protocol;
import stt.protocol.StartMessage;

/// One [Session] per WebSocket connection. Three vthreads cooperate per connection:
///
/// - Helidon's per-connection carrier vthread drives the receive callbacks.
/// - A dedicated **writer** vthread (`stt-writer-N`) drains [#outbox] to the socket.
/// - A **flush** vthread (`stt-flush-N`) ticks at the configured cadence and — when the
///   single-slot inflight CAS is free — runs the inference round-trip *inline* before enqueuing
///   the result.
///
/// The inflight slot is released only after [#outbox] accepts the payload, so a slow client
/// surfaces as oldest-frame-latency growth (back-pressure) rather than unbounded queued
/// inference work — same invariant as the Rust and Go gateways.
public final class Session implements WsListener {

    private static final Logger LOG = Logger.getLogger(Session.class.getName());
    private static final int TYPICAL_BATCH = 50;
    private static final ThreadFactory WRITER_THREADS =
            Thread.ofVirtual().name("stt-writer-", 0).factory();
    private static final ThreadFactory FLUSH_THREADS =
            Thread.ofVirtual().name("stt-flush-", 0).factory();

    private final Config config;
    private final Inference inference;
    private final ObjectMapper jsonMapper;
    private final ObjectWriter partialWriter;
    private final ObjectWriter errorWriter;

    private final AtomicBoolean inflight = new AtomicBoolean(false);
    private final Object bufferLock = new Object();
    final BlockingQueue<String> outbox;

    private final AtomicBoolean closed = new AtomicBoolean(false);
    /** Single-WS-callback-thread invariant: Helidon serializes per-connection callbacks. */
    private boolean started = false;

    long seq = 0L;
    List<Frame> buffer = new ArrayList<>(TYPICAL_BATCH);

    private volatile @Nullable Thread flushThread;
    private volatile @Nullable Thread writerThread;

    public Session(Config config, Inference inference, ObjectMapper jsonMapper) {
        this.config = config;
        this.inference = inference;
        this.jsonMapper = jsonMapper;
        this.partialWriter = jsonMapper.writerFor(PartialMessage.class);
        this.errorWriter = jsonMapper.writerFor(ErrorMessage.class);
        this.outbox = new ArrayBlockingQueue<>(config.partialChannelDepth());
    }

    @Override
    public void onOpen(WsSession session) {
        // Receive callbacks carry the WsSession; the writer vthread is started once with it.
    }

    @Override
    public void onMessage(WsSession session, String text, boolean last) {
        if (closed.get()) {
            return;
        }
        if (started) {
            closeWith(session, Protocol.CLOSE_PROTOCOL_ERROR, Protocol.REASON_TEXT_AFTER_START);
            return;
        }
        try {
            jsonMapper.readValue(text, StartMessage.class);
        } catch (Exception unused) {
            closeWith(session, Protocol.CLOSE_PROTOCOL_ERROR, Protocol.REASON_NEED_START);
            return;
        }
        started = true;
        writerThread = start(WRITER_THREADS, () -> writeLoop(session));
        flushThread = start(FLUSH_THREADS, this::flushLoop);
    }

    @Override
    public void onMessage(WsSession session, BufferData frame, boolean last) {
        if (closed.get()) {
            return;
        }
        if (!started) {
            closeWith(session, Protocol.CLOSE_PROTOCOL_ERROR, Protocol.REASON_NEED_START);
            return;
        }
        if (frame.available() != Protocol.FRAME_BYTES) {
            closeWith(session, Protocol.CLOSE_UNSUPPORTED_DATA, Protocol.REASON_BAD_FRAME_SIZE);
            return;
        }
        var copy = new byte[Protocol.FRAME_BYTES];
        frame.read(copy);
        var receivedAtNanos = System.nanoTime();
        synchronized (bufferLock) {
            seq += 1;
            buffer.add(new Frame(seq, copy, receivedAtNanos));
        }
    }

    @Override
    public void onClose(WsSession session, int status, String reason) {
        shutdown();
    }

    @Override
    public void onError(WsSession session, Throwable t) {
        shutdown();
    }

    private void closeWith(WsSession session, int code, String reason) {
        if (closed.compareAndSet(false, true)) {
            session.close(code, reason);
            interruptWorkers();
        }
    }

    private void writeLoop(WsSession session) {
        while (!closed.get()) {
            String payload;
            try {
                payload = outbox.take();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            try {
                // Text frame on the wire (matches Rust/Go); `last=true` = non-fragmented message.
                session.send(payload, true);
            } catch (RuntimeException e) {
                shutdown();
                return;
            }
        }
    }

    private void flushLoop() {
        var intervalNanos = config.flushInterval().toNanos();
        var jitterRangeNanos = config.flushPhaseJitter().toNanos();
        var expectedNanos = System.nanoTime()
                + intervalNanos
                + (jitterRangeNanos == 0L
                        ? 0L
                        : (long) (ThreadLocalRandom.current().nextDouble() * jitterRangeNanos));

        while (!closed.get()) {
            var delay = expectedNanos - System.nanoTime();
            if (delay > 0) {
                LockSupport.parkNanos(delay);
            }
            if (closed.get()) {
                return;
            }
            var flushLatenessMs = Math.max(0L, System.nanoTime() - expectedNanos) / 1_000_000.0;
            expectedNanos += intervalNanos;
            tryFlush(flushLatenessMs);
        }
    }

    void tryFlush(double flushLatenessMs) {
        if (!inflight.compareAndSet(false, true)) {
            return;
        }
        try {
            var batch = drainBuffer();
            if (!batch.isEmpty()) {
                processBatch(batch, flushLatenessMs);
            }
        } finally {
            inflight.set(false);
        }
    }

    /// Per-flush context shared between the success and error paths. All fields are captured once
    /// per `processBatch` invocation; the error path adds nothing of its own.
    private record FlushContext(List<Frame> batch, int bodyBytes, double flushLatenessMs, long startedAtNanos) {}

    private void processBatch(List<Frame> batch, double flushLatenessMs) {
        var body = concatFrames(batch);
        var ctx = new FlushContext(batch, body.length, flushLatenessMs, System.nanoTime());
        try {
            var prediction = inference.infer(body, config.cpuPasses());
            enqueue(PartialMessage.of(
                    prediction,
                    batch.getFirst().seq(),
                    batch.getLast().seq(),
                    batch.size(),
                    config.cpuPasses(),
                    config.modelDelayMs(),
                    flushLatenessMs));
        } catch (InferenceException err) {
            enqueue(buildError(ctx, err));
        }
    }

    private ErrorMessage buildError(FlushContext ctx, InferenceException err) {
        var oldest = ctx.batch().getFirst();
        var newest = ctx.batch().getLast();
        var nowNanos = System.nanoTime();
        return new ErrorMessage(
                Protocol.ERROR_TYPE,
                err.stage(),
                err.kind(),
                err.getMessage() == null ? "" : err.getMessage(),
                oldest.seq(),
                newest.seq(),
                ctx.batch().size(),
                ctx.bodyBytes(),
                elapsedMs(nowNanos, oldest.receivedAtNanos()),
                elapsedMs(nowNanos, newest.receivedAtNanos()),
                ctx.flushLatenessMs(),
                elapsedMs(nowNanos, ctx.startedAtNanos()),
                1,
                bufferedFrames(),
                err.status(),
                err.retryable());
    }

    private void enqueue(OutboundMessage message) {
        String payload;
        try {
            payload = switch (message) {
                case PartialMessage p -> partialWriter.writeValueAsString(p);
                case ErrorMessage e -> errorWriter.writeValueAsString(e);
            };
        } catch (JsonProcessingException e) {
            LOG.log(Level.WARNING, "drop outbound message; jackson marshal failure", e);
            return;
        }
        try {
            outbox.put(payload);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private List<Frame> drainBuffer() {
        synchronized (bufferLock) {
            if (buffer.isEmpty()) {
                return List.of();
            }
            var batch = buffer;
            buffer = new ArrayList<>(TYPICAL_BATCH);
            return batch;
        }
    }

    int bufferedFrames() {
        synchronized (bufferLock) {
            return buffer.size();
        }
    }

    private void shutdown() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        interruptWorkers();
    }

    private void interruptWorkers() {
        var f = flushThread;
        if (f != null) {
            f.interrupt();
        }
        var w = writerThread;
        if (w != null) {
            w.interrupt();
        }
    }

    private static byte[] concatFrames(List<Frame> batch) {
        var body = new byte[batch.size() * Protocol.FRAME_BYTES];
        var offset = 0;
        for (var frame : batch) {
            System.arraycopy(frame.payload(), 0, body, offset, frame.payload().length);
            offset += frame.payload().length;
        }
        return body;
    }

    private static double elapsedMs(long nowNanos, long earlierNanos) {
        return Math.max(0L, nowNanos - earlierNanos) / 1_000_000.0;
    }

    private static Thread start(ThreadFactory factory, Runnable task) {
        var thread = factory.newThread(task);
        thread.start();
        return thread;
    }
}
