package stt;

import io.helidon.logging.common.LogConfig;
import io.helidon.webserver.WebServer;
import java.util.Optional;
import java.util.logging.Logger;
import stt.config.Config;
import stt.inference.HttpInferenceClient;
import stt.protocol.Protocol;
import stt.server.SttServer;

/// Gateway entry point.
///
/// Uses JEP 512 *instance main methods* (final in JDK 25): no `public static`, no `args`
/// parameter, no class-level boilerplate beyond the package wrapper. The JVM launcher discovers
/// `void main()` directly.
public final class Main {

    private static final Logger LOG = Logger.getLogger(Main.class.getName());

    void main() {
        LogConfig.configureRuntime();

        var config = Config.load();
        var jsonMapper = Protocol.newJsonMapper();
        var inference = new HttpInferenceClient(
                config.inferenceUrl(), config.inferenceTimeout(), config.inferenceHttpClients(), jsonMapper);

        LOG.info(() ->
                "runtime_versions runtime=%s java=%s helidon=%s inference_url=%s flush_interval_ms=%d inference_http_clients=%d"
                        .formatted(
                                Config.RUNTIME_NAME,
                                Runtime.version(),
                                helidonVersion(),
                                config.inferenceUrl(),
                                config.flushInterval().toMillis(),
                                config.inferenceHttpClients()));

        var server = SttServer.create(config, inference, jsonMapper);
        server.start();
        LOG.info(() -> "listening on port " + server.port());
        exitNonZeroIfListenerDies();
    }

    /// Helidon's accept loop catches any Throwable (an OutOfMemoryError included), logs it, and
    /// stops that listener. Its platform thread is the JVM's only non-daemon thread once `main`
    /// returns, so the JVM would then exit 0 and Kubernetes would report a crash as "Completed".
    /// Outlive the listener instead and exit 1. On a real shutdown (SIGTERM) the JVM is already
    /// running its shutdown hooks, so `System.exit` blocks and the signal's status is kept.
    /// (Heap exhaustion is primarily handled by `-XX:+ExitOnOutOfMemoryError` in JAVA_OPTS.)
    private static void exitNonZeroIfListenerDies() {
        var listeners = Thread.getAllStackTraces().keySet().stream()
                .filter(t -> t.getName().startsWith("server-") && t.getName().endsWith("-listener"))
                .toList();
        if (listeners.isEmpty()) {
            LOG.warning("no Helidon listener thread found; listener-death watchdog disabled");
            return;
        }
        for (var listener : listeners) {
            try {
                listener.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        LOG.severe("Helidon listener thread exited; exiting 1");
        System.exit(1);
    }

    private static String helidonVersion() {
        return Optional.ofNullable(WebServer.class.getPackage())
                .map(Package::getImplementationVersion)
                .orElse("unknown");
    }
}
