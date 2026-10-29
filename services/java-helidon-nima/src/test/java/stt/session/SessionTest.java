package stt.session;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.helidon.common.buffers.BufferData;
import io.helidon.common.socket.SocketContext;
import io.helidon.websocket.WsSession;
import java.io.UncheckedIOException;
import java.net.SocketException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.jspecify.annotations.Nullable;
import org.junit.jupiter.api.Test;
import stt.config.Config;
import stt.inference.Inference;
import stt.inference.InferenceException;
import stt.protocol.ErrorKind;
import stt.protocol.ErrorStage;
import stt.protocol.Frame;
import stt.protocol.InferResponse;
import stt.protocol.Protocol;

/**
 * Unit tests for {@link Session}. Drives {@code tryFlush(...)} directly through its
 * package-private hook, mirroring {@code session_test.go}. End-to-end protocol wiring is verified
 * by the cross-runtime conformance check in {@code just conformance}.
 */
final class SessionTest {

    private static final Config CONFIG =
            new Config(5000, "http://stub", Duration.ofSeconds(1), 1, 4, 75L, Duration.ofSeconds(1), Duration.ZERO, 4);
    private static final ObjectMapper MAPPER = Protocol.newJsonMapper();

    private static Session newSession(Inference inference) {
        return new Session(CONFIG, inference, MAPPER);
    }

    private static Frame frame(long seq, byte fill) {
        byte[] payload = new byte[Protocol.FRAME_BYTES];
        Arrays.fill(payload, fill);
        return new Frame(seq, payload, System.nanoTime());
    }

    private static void pushFrame(Session session, Frame f) {
        session.buffer.add(f);
        session.seq = f.seq();
    }

    @Test
    void flushBuildsPartialAndZerosOutTheBuffer() throws Exception {
        InferResponse canned = new InferResponse(1.5, 2L, 3L, 1280L, "now", 1280L);
        Session session = newSession((body, passes) -> canned);
        pushFrame(session, frame(1L, (byte) 0x01));

        session.tryFlush(2.5);
        String payload = session.outbox.poll(1, TimeUnit.SECONDS);

        assertNotNull(payload, "expected a partial payload to be enqueued");
        JsonNode node = MAPPER.readTree(payload);
        assertEquals(Protocol.PARTIAL_TYPE, node.get("type").asText());
        assertEquals(1L, node.get("oldest_frame_seq").asLong());
        assertEquals(1L, node.get("newest_frame_seq").asLong());
        assertEquals(1, node.get("frames").asInt());
        assertEquals(0, session.bufferedFrames());
    }

    @Test
    void secondFlushIsSkippedWhileFirstIsInflight() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        Inference parkOnce = (body, passes) -> {
            calls.incrementAndGet();
            started.countDown();
            try {
                release.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            return new InferResponse(0.0, 0L, 0L, 1L, "x", 1L);
        };
        Session session = newSession(parkOnce);
        pushFrame(session, frame(1L, (byte) 0x01));

        Thread first = Thread.ofPlatform().start(() -> session.tryFlush(0.0));
        assertTrue(started.await(1, TimeUnit.SECONDS), "first inference must have started");

        pushFrame(session, frame(2L, (byte) 0x02));
        session.tryFlush(0.0);
        assertEquals(1, session.bufferedFrames(), "second frame must remain buffered while inflight");

        release.countDown();
        first.join(1000);
        assertFalse(first.isAlive(), "first flush thread must terminate after release");
        assertNotNull(session.outbox.poll(1, TimeUnit.SECONDS));
        assertEquals(1, calls.get(), "inference must be invoked exactly once across the two flushes");
    }

    @Test
    void inferenceFailureRelaysErrorMessage() throws Exception {
        Inference erroring = (body, passes) -> {
            throw new InferenceException(ErrorStage.INFERENCE_REQUEST, ErrorKind.TIMEOUT, "timed out", null, true);
        };
        Session session = newSession(erroring);
        pushFrame(session, frame(1L, (byte) 0x01));

        session.tryFlush(0.0);
        String payload = session.outbox.poll(1, TimeUnit.SECONDS);

        assertNotNull(payload);
        JsonNode node = MAPPER.readTree(payload);
        assertEquals(Protocol.ERROR_TYPE, node.get("type").asText());
        assertEquals(ErrorKind.TIMEOUT.wire(), node.get("kind").asText());
        assertTrue(node.get("retryable").asBoolean());
    }

    /// Records what the gateway writes. Optionally blocks inside `send(String)` to model a writer
    /// that is mid-frame when the receive thread wants to close.
    private static final class FakeWsSession implements WsSession {
        final List<String> events = Collections.synchronizedList(new ArrayList<>());
        volatile int closeCode;
        volatile @Nullable CountDownLatch sendEntered;
        volatile @Nullable CountDownLatch releaseSend;
        /** When set, `send(String)` parks until interrupted (a client that stopped reading). */
        volatile @Nullable CountDownLatch blockUntilInterrupted;

        volatile boolean sendWasInterrupted;

        @Override
        public WsSession send(String text, boolean last) {
            var wedged = blockUntilInterrupted;
            if (wedged != null) {
                wedged.countDown();
                try {
                    new CountDownLatch(1).await();
                } catch (InterruptedException e) {
                    // Mirrors an interrupted vthread blocked in socket I/O: socket closed, send fails.
                    sendWasInterrupted = true;
                    events.add("send-failed");
                    throw new UncheckedIOException(new SocketException("Closed by interrupt"));
                }
            }
            var entered = sendEntered;
            var release = releaseSend;
            if (entered != null && release != null) {
                entered.countDown();
                try {
                    release.await();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
            events.add("text");
            return this;
        }

        @Override
        public WsSession send(BufferData bufferData, boolean last) {
            events.add("binary");
            return this;
        }

        @Override
        public WsSession ping(BufferData bufferData) {
            events.add("ping");
            return this;
        }

        @Override
        public WsSession pong(BufferData bufferData) {
            events.add("pong:" + bufferData.available());
            return this;
        }

        @Override
        public WsSession close(int code, String reason) {
            closeCode = code;
            events.add("close:" + code);
            return this;
        }

        @Override
        public WsSession terminate() {
            return this;
        }

        @Override
        public SocketContext socketContext() {
            throw new UnsupportedOperationException();
        }
    }

    private static final Inference STUB = (body, passes) -> new InferResponse(0.0, 0L, 0L, 1L, "x", 1L);

    private static final String START = "{\"type\":\"start\"}";

    private static BufferData bytes(int size, byte fill) {
        byte[] data = new byte[size];
        Arrays.fill(data, fill);
        return BufferData.create(data);
    }

    private static Session started(FakeWsSession ws) {
        Session session = newSession(STUB);
        session.onMessage(ws, START, true);
        return session;
    }

    @Test
    void invalidFirstMessagesCloseWith1002() {
        for (String text : List.of("not-json", "{\"type\":\"stop\"}")) {
            FakeWsSession ws = new FakeWsSession();
            newSession(STUB).onMessage(ws, text, true);
            assertEquals(Protocol.CLOSE_PROTOCOL_ERROR, ws.closeCode, text);
        }
        FakeWsSession ws = new FakeWsSession();
        newSession(STUB).onMessage(ws, bytes(Protocol.FRAME_BYTES, (byte) 1), true);
        assertEquals(Protocol.CLOSE_PROTOCOL_ERROR, ws.closeCode, "binary before start");
    }

    @Test
    void unfragmentedWrongSizesCloseWith1003() {
        for (int size : new int[] {0, 10, Protocol.FRAME_BYTES - 1, Protocol.FRAME_BYTES + 1}) {
            FakeWsSession ws = new FakeWsSession();
            Session session = started(ws);
            session.onMessage(ws, bytes(size, (byte) 1), true);
            assertEquals(Protocol.CLOSE_UNSUPPORTED_DATA, ws.closeCode, "size " + size);
            assertEquals(0, session.bufferedFrames());
            session.onClose(ws, 1000, "normal");
        }
    }

    @Test
    void fragmentedStartMessageIsReassembled() {
        FakeWsSession ws = new FakeWsSession();
        Session session = newSession(STUB);
        session.onMessage(ws, START.substring(0, 5), false);
        session.onMessage(ws, START.substring(5), true);
        assertEquals(0, ws.closeCode, "fragmented start must be accepted");
        session.onMessage(ws, bytes(Protocol.FRAME_BYTES, (byte) 1), true);
        assertEquals(1, session.bufferedFrames());
        session.onClose(ws, 1000, "normal");
    }

    @Test
    void fragmentedFrameIsReassembledInOrderAndCopied() {
        FakeWsSession ws = new FakeWsSession();
        Session session = started(ws);
        byte[] first = new byte[300];
        byte[] second = new byte[Protocol.FRAME_BYTES - 300];
        Arrays.fill(first, (byte) 1);
        Arrays.fill(second, (byte) 2);
        session.onMessage(ws, BufferData.create(first), false);
        session.onMessage(ws, BufferData.create(second), true);
        // Mutating the caller's buffers afterwards must not change the buffered frame (no aliasing).
        Arrays.fill(first, (byte) 9);
        Arrays.fill(second, (byte) 9);

        assertEquals(0, ws.closeCode);
        assertEquals(1, session.bufferedFrames());
        byte[] expected = new byte[Protocol.FRAME_BYTES];
        Arrays.fill(expected, 0, 300, (byte) 1);
        Arrays.fill(expected, 300, Protocol.FRAME_BYTES, (byte) 2);
        assertArrayEquals(expected, session.buffer.getFirst().payload());
        assertEquals(1L, session.buffer.getFirst().seq());
        session.onClose(ws, 1000, "normal");
    }

    @Test
    void fragmentedMessagesOfWrongTotalSizeCloseWith1003() {
        // Two 640-byte fragments are one 1280-byte message, not two frames.
        FakeWsSession tooBig = new FakeWsSession();
        Session big = started(tooBig);
        big.onMessage(tooBig, bytes(Protocol.FRAME_BYTES, (byte) 1), false);
        big.onMessage(tooBig, bytes(Protocol.FRAME_BYTES, (byte) 1), true);
        assertEquals(Protocol.CLOSE_UNSUPPORTED_DATA, tooBig.closeCode);
        assertEquals(0, big.bufferedFrames());

        FakeWsSession tooSmall = new FakeWsSession();
        Session small = started(tooSmall);
        small.onMessage(tooSmall, bytes(320, (byte) 1), false);
        small.onMessage(tooSmall, bytes(319, (byte) 1), true);
        assertEquals(Protocol.CLOSE_UNSUPPORTED_DATA, tooSmall.closeCode);
        assertEquals(0, small.bufferedFrames());
    }

    @Test
    void pingIsAnsweredWithPong() {
        FakeWsSession ws = new FakeWsSession();
        Session session = started(ws);
        session.onPing(ws, bytes(3, (byte) 7));
        assertEquals(List.of("pong:3"), ws.events);
        session.onClose(ws, 1000, "normal");
    }

    @Test
    void closeWaitsForInProgressSendAndNothingIsSentAfter() throws Exception {
        FakeWsSession ws = new FakeWsSession();
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        ws.sendEntered = entered;
        ws.releaseSend = release;
        Session session = started(ws);
        session.outbox.put("{\"a\":1}");
        assertTrue(entered.await(1, TimeUnit.SECONDS), "writer must be mid-send");
        session.outbox.offer("{\"b\":2}");

        // Helidon calls onClose on the receive thread, then writes its own close frame.
        Thread receiver = Thread.ofPlatform().start(() -> {
            session.onClose(ws, 1000, "normal");
            ws.close(1000, "normal");
        });
        receiver.join(200);
        assertTrue(receiver.isAlive(), "onClose must wait for the in-progress send");

        ws.sendEntered = null;
        release.countDown();
        receiver.join(1000);
        assertFalse(receiver.isAlive());
        Thread.sleep(50);
        assertEquals(List.of("text", "close:1000"), ws.events, "no frame may follow or interleave the close");
    }

    /// A writer wedged forever in `send()` (Helidon has no write timeout) must not hang the
    /// receive thread: after the bounded wait the workers are interrupted, the send fails, and the
    /// close completes — with no partial written after (or interleaved with) the close frame.
    @Test
    void clientCloseCompletesWhenWriterIsWedgedInSend() throws Exception {
        FakeWsSession ws = new FakeWsSession();
        CountDownLatch wedged = new CountDownLatch(1);
        ws.blockUntilInterrupted = wedged;
        Session session = started(ws);
        session.outbox.put("{\"a\":1}");
        assertTrue(wedged.await(1, TimeUnit.SECONDS), "writer must be wedged in send");
        session.outbox.offer("{\"b\":2}");

        long t0 = System.nanoTime();
        Thread receiver = Thread.ofPlatform().start(() -> {
            session.onClose(ws, 1000, "normal");
            ws.close(1000, "normal");
        });
        receiver.join(Session.SEND_LOCK_WAIT_MS * 4);
        long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
        assertFalse(receiver.isAlive(), "onClose must not hang on a wedged writer");
        assertTrue(ws.sendWasInterrupted, "the wedged send must have been interrupted");
        assertTrue(elapsedMs >= Session.SEND_LOCK_WAIT_MS - 50, "interrupt only after the bounded wait");
        Thread.sleep(50);
        assertEquals(List.of("send-failed", "close:1000"), ws.events);
    }

    /// Same, for our own protocol-error close (1003 here) issued from the receive thread.
    @Test
    void protocolErrorCloseCompletesWhenWriterIsWedgedInSend() throws Exception {
        FakeWsSession ws = new FakeWsSession();
        CountDownLatch wedged = new CountDownLatch(1);
        ws.blockUntilInterrupted = wedged;
        Session session = started(ws);
        session.outbox.put("{\"a\":1}");
        assertTrue(wedged.await(1, TimeUnit.SECONDS), "writer must be wedged in send");

        Thread receiver = Thread.ofPlatform().start(() -> session.onMessage(ws, bytes(10, (byte) 1), true));
        receiver.join(Session.SEND_LOCK_WAIT_MS * 4);
        assertFalse(receiver.isAlive(), "closeWith must not hang on a wedged writer");
        assertEquals(Protocol.CLOSE_UNSUPPORTED_DATA, ws.closeCode);
        assertEquals(List.of("send-failed", "close:1003"), ws.events);
    }

    @Test
    void unexpectedFailureBecomesErrorFrameAndFlushingContinues() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        Inference flaky = (body, passes) -> {
            if (calls.incrementAndGet() == 1) {
                throw new IllegalStateException("boom");
            }
            return new InferResponse(0.0, 0L, 0L, 1L, "x", 1L);
        };
        Session session = newSession(flaky);
        pushFrame(session, frame(1L, (byte) 0x01));
        pushFrame(session, frame(2L, (byte) 0x02));

        session.tryFlush(0.0);
        String error = session.outbox.poll(1, TimeUnit.SECONDS);
        assertNotNull(error, "unexpected failure must still produce an error frame");
        JsonNode node = MAPPER.readTree(error);
        assertEquals(Protocol.ERROR_TYPE, node.get("type").asText());
        assertEquals(
                ErrorStage.INFERENCE_RESPONSE_PARSE.wire(), node.get("stage").asText());
        assertEquals(ErrorKind.PARSE_ERROR.wire(), node.get("kind").asText());
        assertTrue(node.get("message").asText().contains("IllegalStateException"));
        assertEquals(1L, node.get("oldest_frame_seq").asLong());
        assertEquals(2L, node.get("newest_frame_seq").asLong());
        assertEquals(2, node.get("frames").asInt());

        pushFrame(session, frame(3L, (byte) 0x03));
        session.tryFlush(0.0);
        JsonNode next = MAPPER.readTree(session.outbox.poll(1, TimeUnit.SECONDS));
        assertEquals(Protocol.PARTIAL_TYPE, next.get("type").asText());
        assertEquals(3L, next.get("oldest_frame_seq").asLong(), "next flush continues the seq range");
    }
}
