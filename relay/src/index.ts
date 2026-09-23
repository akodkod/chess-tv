import { Hono } from "hono";
import { upgradeWebSocket, websocket } from "hono/bun";
import { bodyLimit } from "hono/body-limit";
import { MAX_BYTES } from "@chess-tv/protocol";
import { openDatabase } from "./database";
import { pairingRoutes } from "./pairing";
import { connections } from "./connections";

function numberEnv(name: string, fallback: number, minimum = 1) {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error(`Invalid ${name}`);
  return value;
}
const sql = await openDatabase(process.env.DATABASE_PATH ?? "./data/relay.db");
// Short timings are available only to the subprocess integration harness.
const testing = process.env.NODE_ENV === "test";
const sockets = connections(
  sql,
  testing ? numberEnv("TEST_HEARTBEAT_MS", 20_000) : undefined,
  testing ? numberEnv("TEST_TIMEOUT_MS", 60_000) : undefined,
  testing ? numberEnv("TEST_AUTH_MS", 5000) : undefined,
);
const pairing = pairingRoutes(
  sql,
  (id) => sockets.revoke(id),
  testing ? numberEnv("TEST_PAIRING_TTL_MS", 300_000) : undefined,
);
const app = new Hono();
app.onError((_error, c) => {
  console.error("http_operation_failed");
  return c.json({ error: "internal_error" }, 500);
});
app.use("*", bodyLimit({ maxSize: 4096 }));
app.use("/v1/*", async (c, next) => {
  c.header("Cache-Control", "no-store");
  await next();
});
app.get("/health", (c) => c.json({ status: "ok" }));
app.route("/v1/pairing", pairing.app);
app.get(
  "/v1/ws",
  upgradeWebSocket(() => sockets.events()),
);
const server = Bun.serve({
  hostname: process.env.HOST ?? "127.0.0.1",
  port: numberEnv("PORT", 3000, 0),
  fetch: app.fetch,
  websocket: { ...websocket, maxPayloadLength: MAX_BYTES },
});
console.info(JSON.stringify({ event: "listening", port: server.port }));
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  pairing.stop();
  sockets.stop();
  await server.stop(true);
  await sql.close();
}
process.on("SIGTERM", () => {
  void stop();
});
process.on("SIGINT", () => {
  void stop();
});
