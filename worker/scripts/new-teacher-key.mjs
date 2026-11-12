// Prints a new teacher key and the hash the Worker stores as a secret.
import { createHash, randomBytes } from 'node:crypto';

const key = randomBytes(32).toString('base64url');
const hash = createHash('sha256').update(key).digest('hex');

console.log(`Teacher key (keep this, enter it in the app):\n  ${key}\n`);
console.log(`Hash (production): npx wrangler secret put TEACHER_KEY_HASH\n  ${hash}\n`);
console.log(`Hash (local): add to worker/.dev.vars\n  TEACHER_KEY_HASH=${hash}\n`);
console.log(`Keep the key in a password manager. No part of it is ever given out by the server.`);
