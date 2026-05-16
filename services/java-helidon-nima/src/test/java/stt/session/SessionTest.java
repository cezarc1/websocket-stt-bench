package stt.session;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Duration;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
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
}
