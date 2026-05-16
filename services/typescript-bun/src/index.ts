import { loadConfig } from "./config.ts";
import { startServer } from "./server.ts";

if (import.meta.main) {
  startServer(loadConfig());
}
