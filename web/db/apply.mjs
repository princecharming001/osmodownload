// Migration runner. Applies web/db/migrations/*.sql in filename order against a
// direct Postgres connection (DATABASE_URL), tracking applied versions in an
// osmo_migrations ledger.
//
// CRITICAL: this is a clean NO-OP with a clear message when no database is
// configured, so keyless dev + CI + the test suite never block on it. Applying
// against the real DB is a HUMAN GATE (needs the Supabase/Postgres connection).
//
// Usage:  DATABASE_URL=postgres://... node db/apply.mjs
//   (Supabase → Project Settings → Database → Connection string / "URI".)

import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "migrations");

function migrationFiles() {
  return readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
}

const url = process.env.DATABASE_URL;
if (!url) {
  const files = migrationFiles();
  console.log(
    `[db:migrate] No DATABASE_URL set — skipping (keyless/dev).\n` +
    `[db:migrate] ${files.length} migration(s) on disk: ${files.join(", ")}\n` +
    `[db:migrate] To apply for real: set DATABASE_URL to your Postgres/Supabase URI and re-run.`,
  );
  process.exit(0);
}

let pg;
try {
  pg = await import("pg");
} catch {
  console.error(
    `[db:migrate] DATABASE_URL is set but the 'pg' package isn't installed.\n` +
    `[db:migrate] Run: npm i pg   (then re-run npm run db:migrate)`,
  );
  process.exit(1);
}

const client = new pg.default.Client({ connectionString: url });
await client.connect();
try {
  await client.query(
    `create table if not exists osmo_migrations (version text primary key, applied_at timestamptz not null default now())`,
  );
  const { rows } = await client.query(`select version from osmo_migrations`);
  const done = new Set(rows.map((r) => r.version));

  for (const file of migrationFiles()) {
    if (done.has(file)) { console.log(`[db:migrate] skip ${file} (already applied)`); continue; }
    const sql = readFileSync(join(migrationsDir, file), "utf8");
    console.log(`[db:migrate] apply ${file} ...`);
    await client.query("begin");
    try {
      await client.query(sql);
      await client.query(`insert into osmo_migrations(version) values ($1)`, [file]);
      await client.query("commit");
    } catch (e) {
      await client.query("rollback");
      throw e;
    }
  }
  console.log(`[db:migrate] done.`);
} finally {
  await client.end();
}
