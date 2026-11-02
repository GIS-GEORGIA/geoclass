-- Adds the aerial photo game. SQLite can't change a CHECK in place, so both tables
-- are rebuilt. responses goes first: dropping sessions first would cascade and delete it.
CREATE TABLE sessions_v3 (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  game        TEXT NOT NULL CHECK (game IN ('travel', 'coordinates', 'aerial')),
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paused', 'closed')),
  token_hash  TEXT NOT NULL UNIQUE,
  rev         INTEGER NOT NULL DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  settings    TEXT NOT NULL DEFAULT '{}', -- coordinates and aerial: the task list
  created_at  INTEGER NOT NULL
);

CREATE TABLE responses_v3 (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions_v3(id) ON DELETE CASCADE,
  participant_id TEXT NOT NULL,
  round          INTEGER NOT NULL DEFAULT 0, -- coordinates and aerial: index of the task
  answer         TEXT NOT NULL,
  lat            REAL NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon            REAL NOT NULL CHECK (lon BETWEEN -180 AND 180),
  distance_m     REAL,    -- coordinates and aerial: worked out by the server
  score          INTEGER,
  hidden         INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  created_at     INTEGER NOT NULL,
  UNIQUE (session_id, participant_id, round)
);

INSERT INTO sessions_v3 (id, name, game, status, token_hash, rev, archived, settings, created_at)
  SELECT id, name, game, status, token_hash, rev, archived, settings, created_at FROM sessions;
INSERT INTO responses_v3 (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, created_at)
  SELECT id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, created_at FROM responses;

DROP TABLE responses;
DROP TABLE sessions;
ALTER TABLE sessions_v3 RENAME TO sessions;
ALTER TABLE responses_v3 RENAME TO responses;
CREATE INDEX responses_session ON responses (session_id, created_at);
