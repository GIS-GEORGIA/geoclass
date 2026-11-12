// Checks the newest migration on a seeded, throw-away local D1 database (the same engine as production,
// foreign keys included). Nothing remote is touched.
//
//   node scripts/check-migration.mjs
//   node scripts/check-migration.mjs --from <file.sql>
//
// It applies every migration but the newest, adds scripts/migration-seed.sql, saves every row, applies the
// newest migration, and checks that every row is still there unchanged. Then it tries what the new schema
// should allow and refuse. With --from it starts instead from a `wrangler d1 export` file (a copy of a real
// database, one migration behind), so the newest migration is tried on real data. Only counts and checks
// are printed, never the rows.
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
const worker = path.dirname(here);
const wrangler = path.join(worker, 'node_modules', '.bin', 'wrangler');
const all = readdirSync(path.join(worker, 'migrations')).filter((f) => f.endsWith('.sql')).sort();
const newest = all.at(-1);
const at = process.argv.indexOf('--from');
const from = at > 0 ? path.resolve(process.argv[at + 1] ?? '') : null;

const dir = mkdtempSync(path.join(process.env.TMPDIR ?? tmpdir(), 'geoclass-migration-'));
mkdirSync(path.join(dir, 'migrations'));
const config = path.join(dir, 'wrangler.json');
writeFileSync(
  config,
  JSON.stringify({
    name: 'geoclass-migration-check',
    compatibility_date: '2025-01-01',
    d1_databases: [{ binding: 'DB', database_name: 'check', database_id: '00000000-0000-0000-0000-000000000000', migrations_dir: 'migrations' }],
  }),
);
const local = ['--local', '--persist-to', path.join(dir, 'state'), '--config', config];

function wr(args) {
  return execFileSync(wrangler, args, { cwd: dir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, CI: '1' } });
}
function apply() {
  wr(['d1', 'migrations', 'apply', 'check', ...local]);
}
function sql(command) {
  const out = JSON.parse(wr(['d1', 'execute', 'check', '--json', '--command', command, ...local]));
  return out.at(-1).results;
}
function refused(command) {
  try {
    sql(command);
    return false;
  } catch {
    return true;
  }
}

const sorted = (rows) => JSON.stringify(rows.map((r) => Object.fromEntries(Object.entries(r).sort(([a], [b]) => a.localeCompare(b)))));
const TABLES = { sessions: 'id', responses: 'id', teachers: 'id', auth_failures: 'ip_hash' };
const snapshot = () => Object.fromEntries(Object.entries(TABLES).map(([t, key]) => [t, sql(`SELECT * FROM ${t} ORDER BY ${key}`)]));

let failed = 0;
function check(label, ok) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}`);
  if (!ok) failed++;
}

try {
  for (const f of all.slice(0, -1)) copyFileSync(path.join(worker, 'migrations', f), path.join(dir, 'migrations', f));
  if (from) {
    wr(['d1', 'execute', 'check', '--file', from, ...local]);
    const done = sql('SELECT name FROM d1_migrations ORDER BY id').map((r) => r.name);
    check(`the copy has every migration but ${newest}`, JSON.stringify(done) === JSON.stringify(all.slice(0, -1)));
  } else {
    apply();
    wr(['d1', 'execute', 'check', '--file', path.join(here, 'migration-seed.sql'), ...local]);
  }
  const before = snapshot();

  copyFileSync(path.join(worker, 'migrations', newest), path.join(dir, 'migrations', newest));
  apply();
  const after = snapshot();
  console.log(`Applied ${newest} on ${from ? 'the copy' : 'the seeded database'}.\n`);

  console.log('table          before  after');
  for (const t of Object.keys(TABLES)) {
    console.log(`${t.padEnd(14)} ${String(before[t].length).padStart(6)} ${String(after[t].length).padStart(6)}`);
    check(`${t}: same rows, same values`, sorted(before[t]) === sorted(after[t]));
  }
  if (!from) check('the seed has rows in every table', Object.values(before).every((rows) => rows.length > 0));

  check('quick_check is ok', sql('PRAGMA quick_check')[0].quick_check === 'ok');
  check('no broken foreign keys', sql('PRAGMA foreign_key_check').length === 0);
  const indexes = sql("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'").map((r) => r.name);
  for (const name of ['responses_session', 'sessions_teacher', 'attempts_session', 'attempts_pid']) check(`index ${name} exists`, indexes.includes(name));
  const fk = sql('PRAGMA foreign_key_list(responses)');
  check('responses still points at sessions, with cascade', fk.length === 1 && fk[0].table === 'sessions' && fk[0].on_delete === 'CASCADE');

  // What the new schema allows.
  check(
    'a game the old CHECK did not know',
    !refused("INSERT INTO sessions (id, name, game, token_hash, created_at) VALUES ('s-new', 'New', 'terrain-profile', 'tok-new', 1700000300)"),
  );
  check(
    'an answer without a place',
    !refused("INSERT INTO responses (id, session_id, participant_id, answer, lat, lon, created_at) VALUES ('r-null', 's-new', 'p1', '{}', NULL, NULL, 1700000301)"),
  );
  check(
    'a participant with a nickname',
    !refused("INSERT INTO participants (session_id, pid, nickname, created_at) VALUES ('s-new', 'p1', 'Blue Fox', 1700000302)"),
  );
  check('a participant without a nickname', !refused("INSERT INTO participants (session_id, pid, created_at) VALUES ('s-new', 'p2', 1700000302)"));
  check(
    'an attempt',
    !refused(
      "INSERT INTO attempts (id, session_id, pid, task, answer, score, correct, topics, hints_used, duration_ms, created_at) VALUES ('a1', 's-new', 'p1', 0, '{}', 80, 1, '[\"slope\"]', 1, 4200, 1700000303)",
    ),
  );

  // What it still refuses.
  check('lat without lon is refused', refused("INSERT INTO responses (id, session_id, participant_id, round, answer, lat, lon, created_at) VALUES ('r-x1', 's-new', 'p9', 1, '{}', NULL, 44, 1)"));
  check('lat out of range is refused', refused("INSERT INTO responses (id, session_id, participant_id, round, answer, lat, lon, created_at) VALUES ('r-x2', 's-new', 'p9', 2, '{}', 91, 44, 1)"));
  check('a second answer for the same round is refused', refused("INSERT INTO responses (id, session_id, participant_id, answer, created_at) VALUES ('r-x3', 's-new', 'p1', '{}', 1)"));
  check('an answer to a session that does not exist is refused', refused("INSERT INTO responses (id, session_id, participant_id, answer, created_at) VALUES ('r-x4', 'nope', 'p1', '{}', 1)"));
  check('a bad status is refused', refused("INSERT INTO sessions (id, name, game, status, token_hash, created_at) VALUES ('s-x', 'X', 'travel', 'weird', 'tok-x', 1)"));
  check('a nickname over 20 characters is refused', refused("INSERT INTO participants (session_id, pid, nickname, created_at) VALUES ('s-new', 'p3', 'abcdefghijklmnopqrstu', 1)"));
  check('an empty nickname is refused', refused("INSERT INTO participants (session_id, pid, nickname, created_at) VALUES ('s-new', 'p4', '', 1)"));
  check('the same pid twice in a session is refused', refused("INSERT INTO participants (session_id, pid, created_at) VALUES ('s-new', 'p1', 1)"));
  check('an unknown attempt kind is refused', refused("INSERT INTO attempts (id, session_id, pid, kind, answer, created_at) VALUES ('a-x', 's-new', 'p1', 'other', '{}', 1)"));
  check('negative hints are refused', refused("INSERT INTO attempts (id, session_id, pid, hints_used, answer, created_at) VALUES ('a-y', 's-new', 'p1', -1, '{}', 1)"));

  // Deleting a session takes everything of it along, as the Worker expects.
  sql("DELETE FROM sessions WHERE id = 's-new'");
  const left = sql(
    "SELECT (SELECT COUNT(*) FROM responses WHERE session_id = 's-new') + (SELECT COUNT(*) FROM participants WHERE session_id = 's-new') + (SELECT COUNT(*) FROM attempts WHERE session_id = 's-new') AS n",
  )[0].n;
  check('deleting a session deletes its answers, participants and attempts', left === 0);
  check('the seeded rows are untouched by that', sorted(snapshot().responses) === sorted(after.responses));
} finally {
  rmSync(dir, { recursive: true, force: true });
}

console.log(failed ? `\n${failed} check(s) failed.` : '\nAll checks passed.');
process.exit(failed ? 1 : 0);
