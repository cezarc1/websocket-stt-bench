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
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.LockSupport;
import java.util.concurrent.locks.ReentrantLock;
import java.util.logging.Level;
import java.util.logging.Logger;
import org.jspecify.annotations.Nullable;
import stt.config.Config;
import stt.inference.Inference;
import stt.inference.InferenceException;
import stt.protocol.ErrorKind;
import stt.protocol.ErrorMessage;
import stt.protocol.ErrorStage;
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
///
/// Helidon's `WsSession` send path is not thread-safe (one shared send buffer per connection),
/// and Helidon itself writes close frames from the receive thread. Every outbound frame therefore
/// goes through [#sendLock], and nothing is written after [#closed] flips — see [#shutdown].
/// Helidon sets no write timeout, so a writer whose client stopped reading can sit in `send()`
/// holding the lock indefinitely; the receive thread therefore only ever waits a bounded
/// [#SEND_LOCK_WAIT_MS] for it and then interrupts the workers (which unblocks the socket write)
/// rather than hanging — see [#lockForClose].
///
/// Helidon delivers fragmented messages fragment-by-fragment (`last == false` until FIN), so the
/// 640-byte size rule and start-message parse run on the reassembled message, not per fragment.
public final class Session implements WsListener {

    private static final Logger LOG = Logger.getLogger(Session.class.getName());
    private static final int TYPICAL_BATCH = 50;
    /** Upper bound on a reassembled (fragmented) start message; anything longer is not a start. */
    static final int MAX_START_CHARS = 1024;
    /** Bounded wait for [#sendLock] on the receive thread before interrupting a wedged writer. */
    static final long SEND_LOCK_WAIT_MS = 1000;

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
    private final ReentrantLock sendLock = new ReentrantLock();
    final BlockingQueue<String> outbox;

    private final AtomicBoolean closed = new AtomicBoolean(false);
    /** Single-WS-callback-thread invariant: Helidon serializes per-connection callbacks. */
    private boolean started;
    /** Receive-thread only: text fragments of a not-yet-complete start message. */
    private @Nullable StringBuilder pendingText;
    /** Receive-thread only: binary fragments of a not-yet-complete PCM frame. */
    private byte @Nullable [] pendingFrame;

    private int pendingFrameBytes;

    long seq;
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
        var message = text;
        if (pendingText != null || !last) {
            var pending = pendingText == null ? new StringBuilder() : pendingText;
            pending.append(text);
            if (pending.length() > MAX_START_CHARS) {
                pendingText = null;
                closeWith(session, Protocol.CLOSE_PROTOCOL_ERROR, Protocol.REASON_NEED_START);
                return;
            }
            if (!last) {
                pendingText = pending;
                return;
            }
            pendingText = null;
            message = pending.toString();
        }
        try {
            jsonMapper.readValue(message, StartMessage.class);
        } catch (Exception _) {
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
        var available = frame.available();
        var pending = pendingFrame;
        if (pending == null) {
            if (last) {
                // Fast path: an unfragmented message (what every real client sends).
                if (available != Protocol.FRAME_BYTES) {
                    closeWith(session, Protocol.CLOSE_UNSUPPORTED_DATA, Protocol.REASON_BAD_FRAME_SIZE);
                    return;
                }
                var copy = new byte[Protocol.FRAME_BYTES];
                frame.read(copy);
                append(copy);
                return;
            }
            pending = new byte[Protocol.FRAME_BYTES];
            pendingFrame = pending;
            pendingFrameBytes = 0;
        }
        if (available > Protocol.FRAME_BYTES - pendingFrameBytes) {
            pendingFrame = null;
            closeWith(session, Protocol.CLOSE_UNSUPPORTED_DATA, Protocol.REASON_BAD_FRAME_SIZE);
            return;
        }
        frame.read(pending, pendingFrameBytes, available);
        pendingFrameBytes += available;
        if (!last) {
            return;
        }
        pendingFrame = null;
        if (pendingFrameBytes != Protocol.FRAME_BYTES) {
            closeWith(session, Protocol.CLOSE_UNSUPPORTED_DATA, Protocol.REASON_BAD_FRAME_SIZE);
            return;
        }
        append(pending);
    }

    /** Takes ownership of {@code payload}: it must be a fresh copy, never Helidon's buffer. */
    private void append(byte[] payload) {
        var receivedAtNanos = System.nanoTime();
        synchronized (bufferLock) {
            seq += 1;
            buffer.add(new Frame(seq, payload, receivedAtNanos));
        }
    }

    /** Helidon does not answer pings itself (the default listener is a no-op); RFC 6455 requires a pong. */
    @Override
    public void onPing(WsSession session, BufferData buffer) {
        // Bounded like close: a writer wedged in send() must not hang the receive thread. A pong
        // we can't write without interleaving is dropped (the client isn't reading anyway).
        if (!tryLockSend()) {
            LOG.warning("dropping pong; writer still holds the send lock");
            return;
        }
        try {
            if (!closed.get()) {
                session.pong(buffer);
            }
        } finally {
            sendLock.unlock();
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
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        if (!lockForClose()) {
            // The writer ignored its interrupt and still owns the socket mid-frame. Writing our
            // close frame now would interleave with it, so skip it; the workers are interrupted.
            LOG.severe("close frame not sent; writer still wedged in send() after interrupt");
            return;
        }
        try {
            session.close(code, reason);
            interruptWorkers();
        } finally {
            sendLock.unlock();
        }
    }

    /// Acquires [#sendLock] for a close path, waiting at most [#SEND_LOCK_WAIT_MS]. If a writer is
    /// still holding it (blocked in `send()` to a client that stopped reading), interrupt the
    /// workers — an interrupted virtual thread blocked in socket I/O has its socket closed and the
    /// send fails — then wait once more. [#closed] is already set, so the writer will not send
    /// again once it releases the lock. Returns false only if the lock is still held.
    private boolean lockForClose() {
        if (tryLockSend()) {
            return true;
        }
        LOG.warning("writer held the send lock for " + SEND_LOCK_WAIT_MS + " ms; interrupting workers");
        interruptWorkers();
        return tryLockSend();
    }

    private boolean tryLockSend() {
        try {
            return sendLock.tryLock(SEND_LOCK_WAIT_MS, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
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
            if (!send(session, payload)) {
                return;
            }
        }
    }

    /** Writes one partial under [#sendLock]; false once closed or the socket write failed. */
    private boolean send(WsSession session, String payload) {
        sendLock.lock();
        try {
            if (closed.get()) {
                return false;
            }
            // Text frame on the wire (matches Rust/Go); `last=true` = non-fragmented message.
            session.send(payload, true);
            return true;
        } catch (RuntimeException e) {
            // Includes the failure an interrupt from [#lockForClose] causes in a wedged write.
            // sendLock is reentrant, so shutdown() re-acquires it on this thread without waiting.
            shutdown();
            return false;
        } finally {
            sendLock.unlock();
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
        OutboundMessage message;
        try {
            var prediction = inference.infer(body, config.cpuPasses());
            message = PartialMessage.of(
                    prediction,
                    batch.getFirst().seq(),
                    batch.getLast().seq(),
                    batch.size(),
                    config.cpuPasses(),
                    config.modelDelayMs(),
                    flushLatenessMs);
        } catch (InferenceException err) {
            message = buildError(ctx, err);
        } catch (RuntimeException err) {
            // Any other failure must still report this batch's seq range and leave the flush loop
            // running; an uncaught throw would kill the flush vthread and wedge the session.
            // HttpInferenceClient already maps transport RuntimeExceptions to classified errors,
            // so what reaches here is a response that decoded but can't become a partial (e.g. a
            // null field) — reported as the same parse_error the client uses for undecodable
            // bodies, not as a transport failure (connection_reset) that never happened. The
            // message carries the exception class for anything that isn't actually a parse issue.
            LOG.log(Level.WARNING, "unexpected flush failure", err);
            message = buildError(
                    ctx,
                    new InferenceException(
                            ErrorStage.INFERENCE_RESPONSE_PARSE,
                            ErrorKind.PARSE_ERROR,
                            err.getClass().getSimpleName() + ": " + err.getMessage(),
                            null,
                            false,
                            err));
        }
        enqueue(message);
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

    /// Called from Helidon's receive thread before it writes its own close frame (reply to a client
    /// close, or 1011 after an error). Taking [#sendLock] after flipping [#closed] waits out any
    /// in-progress writer send, and the writer re-checks [#closed] under the lock, so Helidon's
    /// close frame never interleaves with — or is followed by — a partial. The wait is bounded by
    /// [#lockForClose]; a writer wedged in `send()` is interrupted rather than waited on forever.
    private void shutdown() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        if (!lockForClose()) {
            LOG.severe("shutdown proceeding while writer is still wedged in send() after interrupt");
            return;
        }
        try {
            interruptWorkers();
        } finally {
            sendLock.unlock();
        }
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
