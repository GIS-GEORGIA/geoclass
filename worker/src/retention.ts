// Sessions and their answers are deleted this long after they were made (the privacy policy says so).
export const KEEP_SEC = 183 * 24 * 3600;

const nowSec = () => Math.floor(Date.now() / 1000);

/** Run every night: deletes sessions, and their answers, made more than KEEP_SEC ago. */
export async function deleteOld(env: Env, now = nowSec()): Promise<number> {
  const before = now - KEEP_SEC;
  const [, sessions] = await env.DB.batch([
    env.DB.prepare('DELETE FROM responses WHERE session_id IN (SELECT id FROM sessions WHERE created_at < ?)').bind(before),
    env.DB.prepare('DELETE FROM sessions WHERE created_at < ?').bind(before),
  ]);
  return sessions.meta.changes ?? 0;
}

// Failed teacher sign-ins (hashed addresses) are kept for a day at most.
export const AUTH_KEEP_SEC = 24 * 3600;

/** Run every night: deletes the rate limit's records of failed sign-ins older than AUTH_KEEP_SEC. */
export async function deleteOldAuthFailures(env: Env, now = nowSec()): Promise<number> {
  const result = await env.DB.prepare('DELETE FROM auth_failures WHERE window_start < ?').bind(now - AUTH_KEEP_SEC).run();
  return result.meta.changes ?? 0;
}

/**
 * Run every night: deletes teacher accounts (their names) that ended, by expiry or revocation, more than
 * KEEP_SEC ago and no longer own any session.
 */
export async function deleteOldTeachers(env: Env, now = nowSec()): Promise<number> {
  const result = await env.DB.prepare(
    `DELETE FROM teachers WHERE COALESCE(revoked_at, expires_at) < ?
     AND NOT EXISTS (SELECT 1 FROM sessions WHERE sessions.teacher_id = teachers.id)`,
  )
    .bind(now - KEEP_SEC)
    .run();
  return result.meta.changes ?? 0;
}
