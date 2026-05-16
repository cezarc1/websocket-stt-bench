package stt.server;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.helidon.http.HeaderNames;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpRouting;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import io.helidon.webserver.websocket.WsRouting;
import stt.config.Config;
import stt.inference.Inference;
import stt.session.Session;

/** Wires the Helidon {@link WebServer} for the {@code /health} endpoint and the {@code /ws/stt} upgrade. */
public final class SttServer {

    private static final String HEALTH_BODY = """
            {"ok":true,"runtime":"%s"}""".formatted(Config.RUNTIME_NAME);

    private SttServer() {}

    public static WebServer create(Config config, Inference inference, ObjectMapper jsonMapper) {
        return WebServer.builder()
                .port(config.port())
                .routing(SttServer::registerHttp)
                .addRouting(WsRouting.builder().endpoint("/ws/stt", () -> new Session(config, inference, jsonMapper)))
                .build();
    }

    private static void registerHttp(HttpRouting.Builder routing) {
        routing.get("/health", SttServer::health);
    }

    private static void health(ServerRequest request, ServerResponse response) {
        response.header(HeaderNames.CONTENT_TYPE, "application/json");
        response.send(HEALTH_BODY);
    }
}
