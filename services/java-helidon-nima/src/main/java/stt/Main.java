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
    }

    private static String helidonVersion() {
        return Optional.ofNullable(WebServer.class.getPackage())
                .map(Package::getImplementationVersion)
                .orElse("unknown");
    }
}
