-- GeoClass 2.0 schema, the last rebuild of both tables (audit F-05, F-08, section 13):
--   * sessions: no CHECK on game any more. The Worker's GAMES list is the only guard, so a new game
--     needs no migration. Everything else (status and archived checks, teacher_id from 0011) is kept.
--   * responses: lat and lon may be NULL, for games without a place; set together or not at all.
--     Existing rows keep their values, including the 0, 0 that non-spatial games stored.
--   * participants: a pseudonym per session (random id made on the device, optional nickname),
--     never shared between sessions.
--   * attempts: game-agnostic answers for new games. Existing games keep using responses.
-- Teachers and session ownership came in 0011 and are not touched here.
-- As in 0002-0009, responses is dropped first: dropping sessions first would cascade and delete it.
CREATE TABLE sessions_v12 (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  game        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paused', 'closed')),
  token_hash  TEXT NOT NULL UNIQUE,
  rev         INTEGER NOT NULL DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  settings    TEXT NOT NULL DEFAULT '{}', -- the game's own settings, JSON; see the earlier migrations for each game
  created_at  INTEGER NOT NULL,
  teacher_id  TEXT -- NULL for the owner's sessions
);

CREATE TABLE responses_v12 (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions_v12(id) ON DELETE CASCADE,
  participant_id TEXT NOT NULL,
  round          INTEGER NOT NULL DEFAULT 0, -- what the number means depends on the game, see 0009
  answer         TEXT NOT NULL,
  lat            REAL CHECK (lat BETWEEN -90 AND 90),
  lon            REAL CHECK (lon BETWEEN -180 AND 180),
  distance_m     REAL,
  score          INTEGER,
  hidden         INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  accepted       INTEGER NOT NULL DEFAULT 0 CHECK (accepted IN (0, 1)),
  created_at     INTEGER NOT NULL,
  CHECK ((lat IS NULL) = (lon IS NULL)),
  UNIQUE (session_id, participant_id, round)
);

INSERT INTO sessions_v12 (id, name, game, status, token_hash, rev, archived, settings, created_at, teacher_id)
  SELECT id, name, game, status, token_hash, rev, archived, settings, created_at, teacher_id FROM sessions;
INSERT INTO responses_v12 (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at)
  SELECT id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at FROM responses;

DROP TABLE responses;
DROP TABLE sessions;
ALTER TABLE sessions_v12 RENAME TO sessions;
ALTER TABLE responses_v12 RENAME TO responses;
CREATE INDEX responses_session ON responses (session_id, created_at);
CREATE INDEX sessions_teacher ON sessions (teacher_id);

-- One row per student per session. The pid is made on the device for this session only, so two sessions
-- can't be linked by it. The nickname is optional and short; the app asks for a made-up one, not a real name.
CREATE TABLE participants (
  session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  pid         TEXT NOT NULL,
  nickname    TEXT CHECK (nickname IS NULL OR length(nickname) BETWEEN 1 AND 20),
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (session_id, pid)
);

-- One row per scored attempt in a new game. The answer is the game's own JSON; score and correct are
-- worked out by the server. No device details are kept.
CREATE TABLE attempts (
  id           TEXT PRIMARY KEY, -- also the idempotency key, made on the device for each submission
  session_id   TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  pid          TEXT NOT NULL,
  task         INTEGER NOT NULL DEFAULT 0,
  kind         TEXT NOT NULL DEFAULT 'answer' CHECK (kind IN ('answer', 'mistake', 'hint')),
  answer       TEXT NOT NULL,
  score        INTEGER,
  correct      INTEGER CHECK (correct IN (0, 1)),
  topics       TEXT,    -- JSON list of topic codes
  hints_used   INTEGER NOT NULL DEFAULT 0 CHECK (hints_used >= 0),
  duration_ms  INTEGER CHECK (duration_ms >= 0),
  geom         TEXT,    -- optional GeoJSON geometry for map answers
  created_at   INTEGER NOT NULL
);
CREATE INDEX attempts_session ON attempts (session_id, created_at);
CREATE INDEX attempts_pid ON attempts (session_id, pid);
