// Writes openapi.json for the contract package and for the iOS client generator.
// With --check, fails if any committed copy is stale.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildOpenApi } from '../src/index.ts';

const targets = ['../openapi.json', '../../../apps/ios/TaktKit/Sources/TaktAPI/openapi.json'].map((p) =>
  fileURLToPath(new URL(p, import.meta.url)),
);
const next = JSON.stringify(buildOpenApi(), null, 2) + '\n';

if (process.argv.includes('--check')) {
  const stale = targets.filter((file) => {
    try {
      return readFileSync(file, 'utf8') !== next;
    } catch {
      return true;
    }
  });
  if (stale.length) {
    console.error(`openapi.json is out of date (${stale.join(', ')}) — run \`pnpm openapi\`.`);
    process.exit(1);
  }
  console.log('openapi.json is up to date.');
} else {
  for (const file of targets) writeFileSync(file, next);
  console.log('wrote', targets.join('\n      '));
}
