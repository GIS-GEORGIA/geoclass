// A game module: everything the Worker needs to know about one game, in one place. The central code in
// index.ts (create, join, submit, timer, backup, restore) asks the registry for the module and calls it,
// instead of switching on the game's name. Games not moved yet are still handled there directly.

/** The stored result of a student's answer, as read back for a retry or a second try. */
export type StoredAnswer = { round: number; score: number | null; distance_m: number | null };

/** Where the student's answer points, as sent with every submission. */
export type Place = { lat: number; lon: number };

/** What the server works out from an answer: which round it belongs to, and its distance and score if any. */
export type Scored = { round: number; distance: number | null; score: number | null };

export interface GameModule<S extends Record<string, unknown> = Record<string, unknown>> {
  /** The name stored in sessions.game. */
  id: string;
  /** Played against the teacher's clock: the timer works, and answers before the start or after the end are refused. */
  timed: boolean;
  /**
   * 'first': the first answer of each round counts and later ones get its result, so trying again can't
   * find the right answer. 'replace': a new answer from a student replaces their earlier one.
   */
  answers: 'first' | 'replace';
  /** The teacher's settings when the session is made, from the request body. Throws HttpError 400 if bad. */
  settings(body: Record<string, unknown>): S;
  /** What join gives a student: no answers the student should find out only by answering. */
  studentView(settings: S, sessionId: string): Record<string, unknown>;
  /** Only the known fields of an answer, so nothing else a client sends gets stored. Throws HttpError 400 if bad. */
  validateAnswer(raw: unknown, settings: S): Record<string, unknown>;
  /** Scoring, always on the server, also for answers restored from a backup. Throws HttpError 400 if the round is bad. */
  score(settings: S, answer: Record<string, unknown>, place: Place, round: unknown): Scored;
  /** What the student learns after the answer is stored, sent again with every retry. */
  feedback(settings: S, row: StoredAnswer): Record<string, unknown>;
  /** The settings a session restored from a backup keeps. Throws if the file's settings are bad. */
  restoreSettings(raw: unknown): S;
}
