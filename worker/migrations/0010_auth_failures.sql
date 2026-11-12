-- Failed teacher sign-ins per address, for the rate limit in requireTeacher (src/index.ts).
-- Only a hash of the address is kept, and rows older than a day are deleted every night (src/retention.ts).
-- A new table only: nothing existing is rebuilt or changed.
CREATE TABLE auth_failures (
  ip_hash      TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL, -- when the current one-minute window began
  count        INTEGER NOT NULL  -- failures in that window
);
