// Guard: a database URL is accepted ONLY if its parsed host is exactly 127.0.0.1, localhost or ::1.
// Substring checks are unsafe (e.g. "postgresql://127.0.0.1:pw@db.<ref>.supabase.co:5432/postgres" is REMOTE).
// Usage: node scripts/assert-local-db.mjs "$DB_URL"   -> exit 0 and prints host:port, or exit 2 with the reason.
import { fileURLToPath } from "node:url";

export const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]"]);
const ALLOWED_QUERY = new Set(["sslmode", "connect_timeout", "application_name"]);

export function assertLocalDbUrl(raw, env = process.env) {
  if (typeof raw !== "string" || raw.trim() === "") throw new Error("empty database URL");
  if (raw !== raw.trim() || /[\s\u0000-\u001f]/.test(raw)) throw new Error("whitespace/control characters in URL");
  const authority = raw.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").split(/[/?#]/)[0];
  if (authority.includes(",")) throw new Error("multi-host URLs are not allowed");
  let u;
  try { u = new URL(raw); } catch { throw new Error("malformed URL"); }
  if (u.protocol !== "postgresql:" && u.protocol !== "postgres:") throw new Error(`unsupported scheme ${u.protocol}`);
  if (!LOCAL_HOSTS.has(u.hostname)) throw new Error(`host "${u.hostname}" is not local (allowed: 127.0.0.1, localhost, ::1)`);
  if (u.port === "") throw new Error("port must be explicit");
  const port = Number(u.port);
  if (!/^\d+$/.test(u.port) || port < 1024 || port > 65535) throw new Error(`invalid port "${u.port}"`);
  for (const key of u.searchParams.keys()) {
    if (!ALLOWED_QUERY.has(key)) throw new Error(`query parameter "${key}" is not allowed (libpq could redirect the connection)`);
  }
  for (const v of ["PGHOST", "PGHOSTADDR", "PGSERVICE", "PGSERVICEFILE"]) {
    if (env[v]) throw new Error(`environment variable ${v} must not be set (it can redirect libpq)`);
  }
  return { host: u.hostname, port };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const { host, port } = assertLocalDbUrl(process.argv[2] ?? "");
    console.log(`local database target OK: ${host}:${port}`);
  } catch (e) {
    console.error(`REFUSING: ${e.message}`);
    process.exit(2);
  }
}
