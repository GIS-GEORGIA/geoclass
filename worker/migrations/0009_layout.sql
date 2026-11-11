-- Adds the map layout game: one sheet per student (round 0), scored by the server against the legend in the settings.
-- Both tables are rebuilt as in 0005-0008: responses first, because dropping sessions first would cascade and delete it.
CREATE TABLE sessions_v9 (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  game        TEXT NOT NULL CHECK (game IN ('travel', 'coordinates', 'aerial', 'mapping', 'cards', 'evidence', 'plates', 'puzzle', 'layout')),
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paused', 'closed')),
  token_hash  TEXT NOT NULL UNIQUE,
  rev         INTEGER NOT NULL DEFAULT 0,
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  settings    TEXT NOT NULL DEFAULT '{}', -- coordinates, aerial and evidence: the task list. mapping: the timer. cards: the deck and the timer. plates: the deck and the plate on screen. puzzle: the pieces and the timer. layout: the area and the legend
  created_at  INTEGER NOT NULL
);

CREATE TABLE responses_v9 (
  id             TEXT PRIMARY KEY,
  session_id     TEXT NOT NULL REFERENCES sessions_v9(id) ON DELETE CASCADE,
  participant_id TEXT NOT NULL,
  round          INTEGER NOT NULL DEFAULT 0, -- coordinates and aerial: index of the task. mapping: number of the object. cards: the pair found, puzzle: the piece placed, or 100 and up for a wrong try. layout: 0, one sheet per student. evidence: task * 3 + question
  answer         TEXT NOT NULL,
  lat            REAL NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon            REAL NOT NULL CHECK (lon BETWEEN -180 AND 180),
  distance_m     REAL,    -- coordinates, aerial and evidence: worked out by the server
  score          INTEGER,
  hidden         INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  accepted       INTEGER NOT NULL DEFAULT 0 CHECK (accepted IN (0, 1)), -- evidence: the teacher counts it as right
  created_at     INTEGER NOT NULL,
  UNIQUE (session_id, participant_id, round)
);

INSERT INTO sessions_v9 (id, name, game, status, token_hash, rev, archived, settings, created_at)
  SELECT id, name, game, status, token_hash, rev, archived, settings, created_at FROM sessions;
INSERT INTO responses_v9 (id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at)
  SELECT id, session_id, participant_id, round, answer, lat, lon, distance_m, score, hidden, accepted, created_at FROM responses;

DROP TABLE responses;
DROP TABLE sessions;
ALTER TABLE sessions_v9 RENAME TO sessions;
ALTER TABLE responses_v9 RENAME TO responses;
CREATE INDEX responses_session ON responses (session_id, created_at);
