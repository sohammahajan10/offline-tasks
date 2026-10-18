// Runs every migration in supabase/migrations, then every test in
// supabase/tests, on a fresh in-memory Postgres (PGlite) per test file.
//
//   cd tool/sqltest && npm install && npm test
//
// Test files are plain SQL that raise an exception on the first failed check
// and end with a summary row, so they also run unchanged in the Supabase SQL
// editor against a real project (they roll back everything they create).
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const sqlFiles = (dir) =>
  readdirSync(join(root, dir))
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((f) => ({ name: `${dir}/${f}`, sql: readFileSync(join(root, dir, f), 'utf8') }));

const migrations = sqlFiles('supabase/migrations');
const tests = sqlFiles('supabase/tests');
let failures = 0;

for (const test of tests) {
  const db = new PGlite();
  try {
    await db.exec(readFileSync(join(here, 'supabase_stub.sql'), 'utf8'));
    for (const m of migrations) await db.exec(m.sql);
    const results = await db.exec(test.sql);
    const summary = results.filter((r) => r.rows.length).at(-1)?.rows[0];
    console.log(`PASS ${test.name}`);
    if (summary?.checks) {
      for (const line of summary.checks.split('\n')) console.log(`  ✓ ${line}`);
      console.log(`  ${summary.passed} checks passed`);
    }
  } catch (e) {
    failures++;
    console.log(`FAIL ${test.name}\n  ${e.message}`);
  } finally {
    await db.close();
  }
}

// exitCode rather than exit(): exiting while PGlite's WASM handles are still
// closing trips a libuv assertion on Windows.
process.exitCode = failures ? 1 : 0;
