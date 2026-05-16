package stt.config;

import static org.junit.jupiter.api.Assertions.assertEquals;

import java.time.Duration;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

final class ConfigTest {

    private static Function<String, String> env(Map<String, String> values) {
        return values::get;
    }

    @Test
    void defaultsLoadWhenEnvIsEmpty() {
        Config config = Config.load(env(Map.of()));

        assertEquals(Config.DEFAULT_PORT, config.port());
        assertEquals("http://inference-server:9000", config.inferenceUrl());
        assertEquals(Duration.ofMillis(Config.DEFAULT_INFERENCE_TIMEOUT_MS), config.inferenceTimeout());
        assertEquals(Config.DEFAULT_INFERENCE_HTTP_CLIENTS, config.inferenceHttpClients());
        assertEquals(Config.DEFAULT_CPU_PASSES, config.cpuPasses());
        assertEquals(Config.DEFAULT_MODEL_DELAY_MS, config.modelDelayMs());
        assertEquals(Duration.ofMillis(Config.DEFAULT_FLUSH_INTERVAL_MS), config.flushInterval());
        assertEquals(Duration.ZERO, config.flushPhaseJitter());
        assertEquals(Config.DEFAULT_PARTIAL_CHANNEL_DEPTH, config.partialChannelDepth());
    }

    @Test
    void envOverridesAreParsed() {
        Map<String, String> raw = Map.of(
                "PORT", "5050",
                "INFERENCE_URL", "http://example.com:9001/",
                "INFERENCE_TIMEOUT_MS", "3000",
                "INFERENCE_HTTP_CLIENTS", "8",
                "CPU_PASSES", "8",
                "MODEL_DELAY_MS", "100",
                "FLUSH_INTERVAL_MS", "500",
                "FLUSH_PHASE_JITTER_MS", "250",
                "PARTIAL_CHANNEL_DEPTH", "16");
        Config config = Config.load(env(raw));

        assertEquals(5050, config.port());
        assertEquals("http://example.com:9001", config.inferenceUrl());
        assertEquals(Duration.ofSeconds(3), config.inferenceTimeout());
        assertEquals(8, config.inferenceHttpClients());
        assertEquals(8, config.cpuPasses());
        assertEquals(100L, config.modelDelayMs());
        assertEquals(Duration.ofMillis(500), config.flushInterval());
        assertEquals(Duration.ofMillis(250), config.flushPhaseJitter());
        assertEquals(16, config.partialChannelDepth());
    }

    @Test
    void unparseableValuesFallBackToDefaults() {
        Config config = Config.load(env(Map.of("PORT", "not-a-number", "CPU_PASSES", "")));
        assertEquals(Config.DEFAULT_PORT, config.port());
        assertEquals(Config.DEFAULT_CPU_PASSES, config.cpuPasses());
    }
}
