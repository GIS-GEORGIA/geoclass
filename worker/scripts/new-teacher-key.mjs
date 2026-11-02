// Prints a new teacher key and the hash the Worker stores as a secret.
import { createHash, randomBytes } from 'node:crypto';

const key = randomBytes(32).toString('base64url');
const hash = createHash('sha256').update(key).digest('hex');

console.log(`Teacher key (keep this, enter it in the app):\n  ${key}\n`);
console.log(`Hash (production): npx wrangler secret put TEACHER_KEY_HASH\n  ${hash}\n`);
console.log(`Hash (local): add to worker/.dev.vars\n  TEACHER_KEY_HASH=${hash}\n`);
console.log(`The sign-in page's copy button gives out TEACHER_KEY_HINT, if set: the key without its last characters.`);
console.log(`After changing the key, update it too: npx wrangler secret put TEACHER_KEY_HINT`);
