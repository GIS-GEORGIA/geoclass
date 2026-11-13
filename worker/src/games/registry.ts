import { aerial } from './aerial';
import { profile } from './profile';
import { slope } from './slope';
import { viewshed } from './viewshed';
import { travel } from './travel';
import type { GameModule } from './types';

const modules = new Map<string, GameModule>();

/** Adds a game. A new game is one module file and one line in the list below; tests add their own. */
export function registerGame(module: GameModule<any>): void {
  modules.set(module.id, module as GameModule);
}

/** The module of a game, or undefined for a game still handled directly in index.ts. */
export function gameModule(id: string): GameModule | undefined {
  return modules.get(id);
}

export function moduleIds(): string[] {
  return [...modules.keys()];
}

for (const module of [travel, aerial, profile, slope, viewshed]) registerGame(module);
