-- Test data for scripts/check-migration.mjs, in the schema of 0011: every game, an owner's and a teacher's
-- session, hidden and accepted answers, and the 0, 0 that non-spatial games store. Never run on a real database.
INSERT INTO teachers (id, name, key_hash, created_at, expires_at, revoked_at) VALUES
  ('t1', 'Teacher One', 'hash-t1', 1700000000, 1900000000, NULL),
  ('t2', 'Teacher Two', 'hash-t2', 1700000000, 1800000000, 1750000000);

INSERT INTO sessions (id, name, game, status, token_hash, rev, archived, settings, created_at, teacher_id) VALUES
  ('s-travel', 'Travel', 'travel', 'open', 'tok1', 3, 0, '{}', 1700000001, NULL),
  ('s-coord', 'Coordinates', 'coordinates', 'paused', 'tok2', 5, 0, '{"tasks":[{"lat":41.7,"lon":44.8,"mode":"point","format":"dd"}]}', 1700000002, 't1'),
  ('s-aerial', 'Aerial', 'aerial', 'closed', 'tok3', 1, 1, '{"tasks":[{"lat":42.6,"lon":44.6,"photo":"a.webp"}],"answers":"online"}', 1700000003, NULL),
  ('s-mapping', 'Mapping', 'mapping', 'open', 'tok4', 9, 0, '{"seconds":300}', 1700000004, 't1'),
  ('s-cards', 'Cards', 'cards', 'open', 'tok5', 2, 0, '{"pairs":[{"a":"x"},{"a":"y"}],"answers":"online","order":[3,0,2,1]}', 1700000005, NULL),
  ('s-evidence', 'Evidence', 'evidence', 'open', 'tok6', 4, 0, '{"tasks":[{"kind":"photo","lat":41.6,"lon":41.6}]}', 1700000006, 't2'),
  ('s-plates', 'Plates', 'plates', 'open', 'tok7', 0, 0, '{"deck":[1,2]}', 1700000007, NULL),
  ('s-puzzle', 'Puzzle', 'puzzle', 'open', 'tok8', 7, 0, '{"pieces":12}', 1700000008, NULL),
  ('s-layout', 'Layout — ქართული სახელი', 'layout', 'open', 'tok9', 1, 0, '{"legend":[1,2,3]}', 1700000009, 't1');

INSERT INTO responses (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at) VALUES
  ('r01', 's-travel', 'p1', 0, '{"category":"home"}', 41.71, 44.79, NULL, NULL, 0, 0, 1700000100),
  ('r02', 's-travel', 'p2', 0, '{"category":"dream"}', -33.86, 151.2, NULL, NULL, 1, 0, 1700000101),
  ('r03', 's-coord', 'p1', 0, '{"lat":41.7,"lon":44.8}', 41.7, 44.8, 12.5, 100, 0, 0, 1700000102),
  ('r04', 's-coord', 'p2', 0, '{"lat":40,"lon":40}', 40, 40, 412345.6, 10, 0, 0, 1700000103),
  ('r05', 's-aerial', 'p1', 0, '{"lat":42.6,"lon":44.6}', 42.6, 44.6, 0.4, 100, 0, 0, 1700000104),
  ('r06', 's-mapping', 'p1', 1, '{"category":"river"}', 41.5, 44.5, NULL, NULL, 0, 0, 1700000105),
  ('r07', 's-mapping', 'p1', 2, '{"category":"lake"}', 41.6, 44.6, NULL, NULL, 0, 0, 1700000106),
  ('r08', 's-cards', 'p1', 0, '{"ok":true,"pair":0,"a":3,"b":1}', 0, 0, NULL, NULL, 0, 0, 1700000107),
  ('r09', 's-cards', 'p1', 100, '{"ok":false,"x":0,"y":1,"a":0,"b":2}', 0, 0, NULL, NULL, 0, 0, 1700000108),
  ('r10', 's-evidence', 'p1', 0, '{"q":"where","lat":41.6,"lon":41.6}', 41.6, 41.6, 3.2, 100, 0, 0, 1700000109),
  ('r11', 's-evidence', 'p1', 1, '{"q":"name","name":"Kutaisi"}', 0, 0, NULL, 0, 0, 1, 1700000110),
  ('r12', 's-puzzle', 'p3', 5, '{"ok":true}', 0, 0, NULL, NULL, 0, 0, 1700000111),
  ('r13', 's-layout', 'p1', 0, '{"items":[1,2,3]}', 0, 0, NULL, 87, 0, 0, 1700000112);

INSERT INTO auth_failures (ip_hash, window_start, count) VALUES ('iphash1', 1700000200, 3);
