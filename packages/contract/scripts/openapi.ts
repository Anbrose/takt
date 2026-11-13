// Writes packages/contract/openapi.json. With --check, fails if the committed file is stale.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { buildOpenApi } from '../src/index.ts';

const file = fileURLToPath(new URL('../openapi.json', import.meta.url));
const next = JSON.stringify(buildOpenApi(), null, 2) + '\n';
if (process.argv.includes('--check')) {
  let cur = '';
  try {
    cur = readFileSync(file, 'utf8');
  } catch {}
  if (cur !== next) {
    console.error('openapi.json is out of date — run `pnpm openapi`.');
    process.exit(1);
  }
  console.log('openapi.json is up to date.');
} else {
  writeFileSync(file, next);
  console.log('wrote', file);
}
