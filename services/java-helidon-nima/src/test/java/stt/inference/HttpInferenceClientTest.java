package stt.inference;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.sun.net.httpserver.HttpServer;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.Test;
import stt.protocol.Protocol;

/** Black-box tests of {@link HttpInferenceClient} against a local HTTP/1.1 stub server. */
final class HttpInferenceClientTest {

    private static final byte[] RESPONSE = """
            {"rms":1.0,"zero_crossings":2,"checksum":3,"samples":320,"transcript":"x","audio_bytes":640}""".getBytes(StandardCharsets.UTF_8);

    /// Helidon 4.3.0 watches an idle pooled HTTP/1.1 connection with a virtual thread doing
    /// 101 ms socket reads until the read timeout has elapsed. A connection reused during that
    /// thread's last read fails ("Exception in socket monitor thread.") whenever the response
    /// arrives after that read times out. With a 300 ms read timeout the monitor gives up at about
    /// 303 ms, so a reuse at ~240 ms idle with a 150 ms response lands in the window. (In the
    /// gateway the window is idle ~2.0-2.1 s, which flush phase jitter makes reachable.)
    @Test
    void reuseDuringIdleMonitorLastReadIsRetried() throws Exception {
        var server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/infer", exchange -> {
            try (exchange) {
                exchange.getRequestBody().readAllBytes();
                Thread.sleep(150);
                exchange.sendResponseHeaders(200, RESPONSE.length);
                exchange.getResponseBody().write(RESPONSE);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        });
        server.start();
        try {
            var client = new HttpInferenceClient(
                    "http://127.0.0.1:" + server.getAddress().getPort(),
                    Duration.ofMillis(300),
                    1,
                    Protocol.newJsonMapper());
            var body = new byte[Protocol.FRAME_BYTES];
            for (var i = 0; i < 3; i++) {
                assertEquals(3, client.infer(body, 1).checksum());
                Thread.sleep(240);
            }
        } finally {
            server.stop(0);
        }
    }
}
