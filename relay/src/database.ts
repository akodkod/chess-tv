import { SQL } from "bun";
import { mkdir } from "node:fs/promises";
import { dirname } from "node:path";
import { createHash, randomBytes } from "node:crypto";
import type { Role } from "@chess-tv/protocol";
export const secret = () => randomBytes(32).toString("hex");
export const hash = (value: string) => createHash("sha256").update(value).digest("hex");
export async function openDatabase(filename: string) {
  await mkdir(dirname(filename), { recursive: true });
  const sql = new SQL({ adapter: "sqlite", filename });
  await sql`PRAGMA journal_mode = WAL`;
  await sql`CREATE TABLE IF NOT EXISTS pairings (id TEXT PRIMARY KEY, tv_hash TEXT UNIQUE NOT NULL, extension_hash TEXT UNIQUE NOT NULL)`;
  return sql;
}
export async function authenticate(
  sql: SQL,
  token: string,
): Promise<{ pairingId: string; role: Role } | null> {
  const digest = hash(token);
  const rows =
    await sql`SELECT id, tv_hash FROM pairings WHERE tv_hash = ${digest} OR extension_hash = ${digest}`;
  const row = rows[0] as { id: string; tv_hash: string } | undefined;
  return row ? { pairingId: row.id, role: row.tv_hash === digest ? "tv" : "extension" } : null;
}
