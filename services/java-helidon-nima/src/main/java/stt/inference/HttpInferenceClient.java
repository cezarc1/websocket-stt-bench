package stt.inference;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.helidon.http.HeaderName;
import io.helidon.http.HeaderNames;
import io.helidon.http.Status;
import io.helidon.webclient.api.HttpClientResponse;
import io.helidon.webclient.api.WebClient;
import io.helidon.webclient.http2.Http2ClientProtocolConfig;
import java.io.IOException;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Stream;
import stt.protocol.ErrorKind;
import stt.protocol.ErrorStage;
import stt.protocol.InferResponse;

/**
 * Pool of HTTP/2 (h2c, prior-knowledge) Helidon WebClient instances for posting batched PCM to the
 * shared inference server. Round-robin selection mirrors the Go gateway.
 */
public final class HttpInferenceClient implements Inference {

    public static final String CPU_PASSES_HEADER = "x-cpu-passes";
    private static final HeaderName CPU_PASSES = HeaderNames.create(CPU_PASSES_HEADER);
    private static final String INFER_PATH = "/infer";

    private final List<WebClient> clients;
    private final ObjectMapper jsonMapper;
    private final AtomicLong next = new AtomicLong();

    public HttpInferenceClient(String baseUrl, Duration timeout, int clientCount, ObjectMapper jsonMapper) {
        var n = Math.max(1, clientCount);
        this.clients = new ArrayList<>(n);
        for (var i = 0; i < n; i++) {
            clients.add(WebClient.builder()
                    .baseUri(baseUrl)
                    .readTimeout(timeout)
                    .connectTimeout(timeout)
                    .addProtocolConfig(Http2ClientProtocolConfig.builder()
                            .priorKnowledge(true)
                            .build())
                    .build());
        }
        this.jsonMapper = jsonMapper;
    }

    /// Message of the exception Helidon 4.3.0 `IdleInputStream.endIdle` throws (wrapping an
    /// `ExecutionException`) when a pooled HTTP/1.1 connection is reused during its idle monitor's
    /// last 101 ms read: that read times out even though reuse cancelled the monitor, so the request
    /// fails although it was healthy. It strikes when a connection sits idle for ~the read timeout
    /// (2 s by default), which 1 s flush phase jitter makes reachable.
    private static final String IDLE_MONITOR_RACE = "Exception in socket monitor thread.";

    /// Posts once; if Helidon's idle-monitor race (above) killed a reused connection, posts once more
    /// on a fresh one (the dead connection is marked closed and never pooled again). Inference is a
    /// pure function of the body, so re-sending is safe, and this stays one call at a time per session.
    @Override
    public InferResponse infer(byte[] body, int cpuPasses) {
        try {
            return post(body, cpuPasses);
        } catch (RuntimeException first) {
            if (!lostIdleMonitorRace(first)) {
                throw classify(first);
            }
        }
        try {
            return post(body, cpuPasses);
        } catch (RuntimeException retryErr) {
            throw classify(retryErr);
        }
    }

    private InferResponse post(byte[] body, int cpuPasses) {
        try (HttpClientResponse response = pick().post()
                .path(INFER_PATH)
                .header(CPU_PASSES, Integer.toString(cpuPasses))
                .submit(body)) {
            var code = response.status().code();
            if (code < 200 || code >= 300) {
                throw classifyStatus(code);
            }
            try {
                return jsonMapper.readValue(response.as(byte[].class), InferResponse.class);
            } catch (IOException parseErr) {
                throw new InferenceException(
                        ErrorStage.INFERENCE_RESPONSE_PARSE,
                        ErrorKind.PARSE_ERROR,
                        describe(parseErr),
                        code,
                        false,
                        parseErr);
            }
        }
    }

    private static boolean lostIdleMonitorRace(Throwable err) {
        return Stream.iterate(err, Objects::nonNull, Throwable::getCause)
                .anyMatch(t -> IDLE_MONITOR_RACE.equals(t.getMessage()) && t.getCause() instanceof ExecutionException);
    }

    private static InferenceException classify(RuntimeException err) {
        return err instanceof InferenceException classified ? classified : classifyRequest(err);
    }

    private WebClient pick() {
        return clients.get(Math.floorMod(next.getAndIncrement(), clients.size()));
    }

    private static InferenceException classifyStatus(int code) {
        var is429 = code == Status.TOO_MANY_REQUESTS_429.code();
        return new InferenceException(
                ErrorStage.INFERENCE_REQUEST,
                is429 ? ErrorKind.HTTP_429 : ErrorKind.HTTP_5XX,
                "inference returned status " + code,
                code,
                is429 || (code >= 500 && code < 600));
    }

    private static InferenceException classifyRequest(Throwable err) {
        var timedOut =
                Stream.iterate(err, Objects::nonNull, Throwable::getCause).anyMatch(HttpInferenceClient::isTimeout);
        return new InferenceException(
                ErrorStage.INFERENCE_REQUEST,
                timedOut ? ErrorKind.TIMEOUT : ErrorKind.CONNECTION_RESET,
                describe(err),
                null,
                true,
                err);
    }

    private static boolean isTimeout(Throwable t) {
        return switch (t) {
            case TimeoutException _ -> true;
            case SocketTimeoutException _ -> true;
            case SocketException s
            when s.getMessage() != null
                    && s.getMessage().toLowerCase(Locale.ROOT).contains("timed out") -> true;
            default -> false;
        };
    }

    private static String describe(Throwable err) {
        var message = err.getMessage();
        return message == null ? err.getClass().getSimpleName() : message;
    }
}
