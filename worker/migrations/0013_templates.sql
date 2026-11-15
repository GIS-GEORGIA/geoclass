-- Templates: what a teacher prepares once and makes sessions from again and again (the 112 game's points,
-- scenarios and photos). Only new things are added; no table is rebuilt.
--   * teacher_id: the teacher who made it, NULL for the owner's, as in sessions.
--   * data: the game's own template, JSON, checked by the game's module (worker/src/games/*.ts).
-- A template's photos are in R2 under photos/<template id>/ and go when it is deleted.
CREATE TABLE templates (
  id          TEXT PRIMARY KEY,
  teacher_id  TEXT,
  game        TEXT NOT NULL,
  name        TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  data        TEXT NOT NULL DEFAULT '{}',
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
CREATE INDEX templates_teacher ON templates (teacher_id, game);
