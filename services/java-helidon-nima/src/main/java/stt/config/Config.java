package stt.config;

import java.time.Duration;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Env-var-backed configuration. Mirrors the Go gateway's {@code internal/config/config.go}. */
public record Config(
        int port,
        String inferenceUrl,
        Duration inferenceTimeout,
        int inferenceHttpClients,
        int cpuPasses,
        long modelDelayMs,
        Duration flushInterval,
        Duration flushPhaseJitter,
        int partialChannelDepth) {

    public static final int DEFAULT_PORT = 5000;
    public static final String DEFAULT_INFERENCE_URL = "http://inference-server:9000";
    public static final int DEFAULT_INFERENCE_TIMEOUT_MS = 2000;
    public static final int DEFAULT_INFERENCE_HTTP_CLIENTS = 4;
    public static final int DEFAULT_CPU_PASSES = 4;
    public static final long DEFAULT_MODEL_DELAY_MS = 75;
    public static final long DEFAULT_FLUSH_INTERVAL_MS = 1000;
    public static final long DEFAULT_FLUSH_PHASE_JITTER_MS = 0;
    public static final int DEFAULT_PARTIAL_CHANNEL_DEPTH = 4;

    public static final String RUNTIME_NAME = "java-helidon-nima";

    public static Config load() {
        return load(System::getenv);
    }

    /** Visible for testing: injectable {@code getenv} lets tests build configs without mutating the process env. */
    public static Config load(Function<String, @Nullable String> getenv) {
        return new Config(
                (int) envLong(getenv, "PORT", DEFAULT_PORT),
                envString(getenv, "INFERENCE_URL", DEFAULT_INFERENCE_URL).replaceAll("/+$", ""),
                Duration.ofMillis(envLong(getenv, "INFERENCE_TIMEOUT_MS", DEFAULT_INFERENCE_TIMEOUT_MS)),
                (int) Math.max(1L, envLong(getenv, "INFERENCE_HTTP_CLIENTS", DEFAULT_INFERENCE_HTTP_CLIENTS)),
                (int) Math.max(1L, envLong(getenv, "CPU_PASSES", DEFAULT_CPU_PASSES)),
                Math.max(0L, envLong(getenv, "MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS)),
                Duration.ofMillis(Math.max(1L, envLong(getenv, "FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS))),
                Duration.ofMillis(
                        Math.max(0L, envLong(getenv, "FLUSH_PHASE_JITTER_MS", DEFAULT_FLUSH_PHASE_JITTER_MS))),
                (int) Math.max(1L, envLong(getenv, "PARTIAL_CHANNEL_DEPTH", DEFAULT_PARTIAL_CHANNEL_DEPTH)));
    }

    private static String envString(Function<String, @Nullable String> getenv, String name, String fallback) {
        String value = getenv.apply(name);
        return (value == null || value.isEmpty()) ? fallback : value;
    }

    private static long envLong(Function<String, @Nullable String> getenv, String name, long fallback) {
        String raw = getenv.apply(name);
        if (raw == null || raw.isEmpty()) {
            return fallback;
        }
        try {
            return Long.parseLong(raw);
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }
}
