import { type AppConfig, loadConfig } from "./config.ts";
import { createInferenceRunner, type InferenceRunner } from "./inference.ts";
import { SttSession } from "./session.ts";

interface WebSocketData {
  config: AppConfig;
  inference: InferenceRunner;
  session?: SttSession;
}

export function startServer(config: AppConfig = loadConfig()): Bun.Server<WebSocketData> {
  const inference = createInferenceRunner(config.inferenceUrl, config.inferenceTimeoutMs);

  const server = Bun.serve<WebSocketData>({
    port: config.port,
    fetch(request, server) {
      const url = new URL(request.url);
      if (url.pathname === "/health") {
        return Response.json({ ok: true, runtime: "typescript-bun" });
      }
      if (url.pathname === "/ws/stt" && server.upgrade(request, { data: { config, inference } })) {
        return undefined;
      }
      return new Response("not found", { status: 404 });
    },
    websocket: {
      // Frames are 640 B PCM and start is a tiny JSON. Cap is generous so
      // oversized binary frames hit our 1003 close path in session.ts
      // rather than Bun's 1009 (Message Too Big), matching the shared
      // close-code contract enforced by the other gateways.
      maxPayloadLength: 8 * 1024,
      backpressureLimit: 1024 * 1024,
      closeOnBackpressureLimit: false,
      open(ws) {
        ws.data.session = new SttSession(ws, {
          ...ws.data.config,
          inference: ws.data.inference,
        });
      },
      message(ws, message) {
        ws.data.session?.handleMessage(message);
      },
      drain(ws) {
        ws.data.session?.drain();
      },
      close(ws) {
        ws.data.session?.close();
      },
    },
  });

  console.info(
    "runtime_versions runtime=typescript-bun bun=%s valibot=1.4.0 inference_url=%s flush_interval_ms=%d",
    Bun.version,
    config.inferenceUrl,
    config.flushIntervalMs,
  );
  console.info("listening addr=0.0.0.0:%d", config.port);
  return server;
}
