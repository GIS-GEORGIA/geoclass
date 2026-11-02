-- A session is one run of one game for one group of students.
CREATE TABLE sessions (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  game        TEXT NOT NULL CHECK (game IN ('travel')),
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paused', 'closed')),
  token_hash  TEXT NOT NULL UNIQUE,
  rev         INTEGER NOT NULL DEFAULT 0, -- bumped on every change, lets polling skip unchanged data
  archived    INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  created_at  INTEGER NOT NULL
);

-- Students are anonymous: participant_id is a random id made on the device.
CREATE TABLE responses (
  id             TEXT PRIMARY KEY, -- also the idempotency key, made on the device for each submission
  session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  participant_id TEXT NOT NULL,
  answer         TEXT NOT NULL,
  lat            REAL NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lon            REAL NOT NULL CHECK (lon BETWEEN -180 AND 180),
  hidden         INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
  created_at     INTEGER NOT NULL,
  UNIQUE (session_id, participant_id)
);

CREATE INDEX responses_session ON responses (session_id, created_at);
