import { type AppConfig, loadConfig } from "./config.ts";
import { createInferenceRunner, type InferenceRunner } from "./inference.ts";
import { SttSession } from "./session.ts";

// Frames are 640 B PCM and start is a tiny JSON; the cap only has to be large
// enough that oversized binary frames reach session.ts's own size check and
// close 1003 per the shared contract. Bun (uWebSockets) does not hand frames
// above maxPayloadLength to the handler: it drops the connection itself
// (observed client-side as 1006, not 1003). So frames up to this cap,
// which covers the conformance harness's 8193 and 65536 byte cases, get 1003;
// anything larger cannot be mapped to 1003 by this gateway.
export const MAX_PAYLOAD_BYTES = 128 * 1024;

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
      maxPayloadLength: MAX_PAYLOAD_BYTES,
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
    "runtime_versions runtime=typescript-bun bun=%s valibot=1.4.2 inference_url=%s flush_interval_ms=%d",
    Bun.version,
    config.inferenceUrl,
    config.flushIntervalMs,
  );
  console.info("listening addr=0.0.0.0:%d", config.port);
  return server;
}
