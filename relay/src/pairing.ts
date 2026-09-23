import { randomInt, randomUUID } from "node:crypto";
import type { SQL } from "bun";
import { Hono } from "hono";
import { getConnInfo } from "hono/bun";
import { z } from "zod";
import { authenticate, hash, secret } from "./database";

type Challenge = {
  id: string;
  code: string;
  tv: string;
  extension?: string;
  expiresAt: number;
  state: "waiting" | "claimed" | "confirmed" | "rejected";
  pairingId?: string;
  tvCredential?: string;
  extensionCredential?: string;
  busy?: boolean;
};
export function pairingRoutes(sql: SQL, revoke: (id: string) => void, ttlMs = 300_000) {
  const challenges = new Map<string, Challenge>();
  const limits = new Map<string, { count: number; until: number }>();
  function sweep() {
    const now = Date.now();
    for (const [id, c] of challenges) if (c.expiresAt <= now && !c.busy) challenges.delete(id);
    for (const [ip, bucket] of limits) if (bucket.until <= now) limits.delete(ip);
  }
  const timer = setInterval(sweep, Math.min(ttlMs, 30_000));
  const app = new Hono();
  app.use("*", async (c, next) => {
    sweep();
    if (
      c.req.method === "POST" &&
      ["/", "/claim"].some((p) => c.req.path === `/v1/pairing${p === "/" ? "" : p}`)
    ) {
      const key = `${getConnInfo(c).remote.address ?? "unknown"}:${c.req.path}`;
      let bucket = limits.get(key);
      if (!bucket) {
        if (limits.size >= 10_000) return c.json({ error: "busy" }, 503);
        bucket = { count: 0, until: Date.now() + 60_000 };
        limits.set(key, bucket);
      }
      if (++bucket.count > (c.req.path.endsWith("/claim") ? 10 : 5))
        return c.json({ error: "rate_limited" }, 429);
    }
    await next();
  });
  app.post("/", (c) => {
    if (challenges.size >= 1000) return c.json({ error: "busy" }, 503);
    let code: string;
    do {
      code = String(randomInt(1_000_000)).padStart(6, "0");
    } while ([...challenges.values()].some((ch) => ch.code === code));
    const token = secret();
    const challenge: Challenge = {
      id: randomUUID(),
      code,
      tv: hash(token),
      expiresAt: Date.now() + ttlMs,
      state: "waiting",
    };
    challenges.set(challenge.id, challenge);
    return c.json({ challengeId: challenge.id, code, token, expiresAt: challenge.expiresAt }, 201);
  });
  app.post("/claim", async (c) => {
    const body = z
      .strictObject({ code: z.string().regex(/^\d{6}$/) })
      .safeParse(await c.req.json().catch(() => null));
    if (!body.success) return c.json({ error: "invalid_request" }, 400);
    const challenge = [...challenges.values()].find(
      (ch) => ch.code === body.data.code && ch.state === "waiting" && ch.expiresAt > Date.now(),
    );
    if (!challenge) return c.json({ error: "invalid_code" }, 404);
    const token = secret();
    challenge.extension = hash(token);
    challenge.state = "claimed";
    return c.json({ challengeId: challenge.id, token, expiresAt: challenge.expiresAt });
  });
  app.get("/:id", (c) => {
    const challenge = challenges.get(c.req.param("id"));
    const digest = hash(c.req.header("Authorization")?.replace(/^Bearer /, "") ?? "");
    const role =
      challenge?.tv === digest ? "tv" : challenge?.extension === digest ? "extension" : null;
    if (!challenge || !role) return c.json({ error: "invalid_challenge" }, 404);
    return c.json({
      state: challenge.state,
      expiresAt: challenge.expiresAt,
      ...(challenge.state === "confirmed"
        ? {
            pairingId: challenge.pairingId,
            credential: role === "tv" ? challenge.tvCredential : challenge.extensionCredential,
          }
        : {}),
    });
  });
  app.post("/:id/decision", async (c) => {
    const body = z
      .strictObject({ confirm: z.boolean() })
      .safeParse(await c.req.json().catch(() => null));
    if (!body.success) return c.json({ error: "invalid_request" }, 400);
    const challenge = challenges.get(c.req.param("id"));
    if (
      !challenge ||
      challenge.expiresAt <= Date.now() ||
      challenge.tv !== hash(c.req.header("Authorization")?.replace(/^Bearer /, "") ?? "")
    )
      return c.json({ error: "invalid_challenge" }, 404);
    if (challenge.busy) return c.json({ error: "busy" }, 409);
    if (challenge.state === "confirmed" || challenge.state === "rejected")
      return c.json({ state: challenge.state });
    if (challenge.state !== "claimed") return c.json({ error: "not_claimed" }, 409);
    if (!body.data.confirm) {
      challenge.state = "rejected";
      return c.json({ state: challenge.state });
    }
    challenge.busy = true;
    try {
      const pairingId = randomUUID(),
        tv = secret(),
        extension = secret();
      await sql`INSERT INTO pairings (id, tv_hash, extension_hash) VALUES (${pairingId}, ${hash(tv)}, ${hash(extension)})`;
      Object.assign(challenge, {
        pairingId,
        tvCredential: tv,
        extensionCredential: extension,
        state: "confirmed",
      });
      return c.json({ state: challenge.state });
    } finally {
      challenge.busy = false;
    }
  });
  app.delete("/", async (c) => {
    const device = await authenticate(
      sql,
      c.req.header("Authorization")?.replace(/^Bearer /, "") ?? "",
    );
    if (!device) return c.json({ error: "unauthorized" }, 401);
    await sql`DELETE FROM pairings WHERE id = ${device.pairingId}`;
    for (const [id, challenge] of challenges)
      if (challenge.pairingId === device.pairingId) challenges.delete(id);
    revoke(device.pairingId);
    return c.body(null, 204);
  });
  return { app, stop: () => clearInterval(timer) };
}
