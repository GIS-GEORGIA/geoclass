-- Teacher accounts besides the owner. The owner keeps the TEACHER_KEY_HASH secret and can do everything;
-- each teacher here has their own key (only its hash is kept), sees only their own sessions, and stops
-- working at expires_at or when revoked. Only new things are added: no table is rebuilt.
CREATE TABLE teachers (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  key_hash    TEXT NOT NULL UNIQUE,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  revoked_at  INTEGER
);

-- The teacher who made the session; NULL for the owner's sessions, which is every session made before this.
ALTER TABLE sessions ADD COLUMN teacher_id TEXT;
CREATE INDEX sessions_teacher ON sessions (teacher_id);
