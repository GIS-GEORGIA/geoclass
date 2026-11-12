import { HttpError, distanceM, scoreFor, validateTasks, type Task } from '../validate';
import type { GameModule } from './types';

type AerialSettings = { tasks: Task[]; answers?: string };

const ANSWER_MODES = ['online', 'offline'];

/**
 * Aerial photos: the student finds where a photo was taken and taps it on the map. The first tap of a task
 * counts and is scored by its distance. Online (the default) the places stay on the server until answered;
 * offline the device knows them and checks itself. Sessions from before the choice have no mode: offline.
 */
export const aerial: GameModule<AerialSettings> = {
  id: 'aerial',
  timed: false,
  answers: 'first',
  settings(body) {
    if (body.answers !== undefined && !ANSWER_MODES.includes(body.answers as string)) throw new HttpError(400, 'bad_answers');
    return { tasks: validateTasks('aerial', body.tasks), answers: (body.answers as string | undefined) ?? 'online' };
  },
  studentView(settings) {
    if (settings.answers !== 'online') return settings;
    return { ...settings, tasks: settings.tasks.map((t) => ({ mode: t.mode, format: t.format, photo: t.photo })) };
  },
  // The round and the point say everything about an aerial answer.
  validateAnswer(raw) {
    if (typeof raw !== 'object' || raw === null) throw new HttpError(400, 'bad_answer');
    return {};
  },
  score(settings, _answer, place, round) {
    const task = typeof round === 'number' ? settings.tasks[round] : undefined;
    if (!task) throw new HttpError(400, 'bad_round');
    const distance = distanceM(place.lat, place.lon, task.lat, task.lon);
    return { round: round as number, distance, score: scoreFor(distance) };
  },
  feedback(settings, row) {
    const t = settings.tasks[row.round];
    if (!t) return {};
    return { score: row.score, distanceM: row.distance_m, target: { lat: t.lat, lon: t.lon, label: t.label ?? '', labelEn: t.labelEn ?? '' } };
  },
  restoreSettings(raw) {
    const r = (typeof raw === 'object' && raw !== null ? raw : {}) as { tasks?: unknown; answers?: unknown };
    const tasks = validateTasks('aerial', r.tasks);
    // The answer mode comes back as it was; a backup from before it existed has none, which means offline.
    return ANSWER_MODES.includes(r.answers as string) ? { tasks, answers: r.answers as string } : { tasks };
  },
};
