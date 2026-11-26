// Manual, paid call to the configured model. Not run in CI.
// Usage: VERTEX_PROJECT=... pnpm --filter @takt/api exec tsx scripts/try-extract.ts transcript.json
// transcript.json: { "locale": "zh_CN", "speakers": [{id,name}], "lines": [{startMs,endMs,text,speaker}] }
import { readFileSync } from 'node:fs';
import { config } from '../src/config.ts';
import { chunkLines } from '../src/llm/extractor.ts';
import { VertexExtractor } from '../src/llm/vertex-extractor.ts';

const file = process.argv[2];
if (!file) throw new Error('usage: try-extract.ts <transcript.json>');
if (!config.vertexProject) throw new Error('VERTEX_PROJECT is required');
const input = JSON.parse(readFileSync(file, 'utf8'));
const extractor = new VertexExtractor({
  project: config.vertexProject,
  location: config.vertexLocation,
  model: config.llmModel,
});
const started = Date.now();
const chains = [];
for (const lines of chunkLines(input.lines)) {
  chains.push(
    ...(await extractor.extract({ locale: input.locale ?? 'zh_CN', speakers: input.speakers ?? [], lines })),
  );
}
console.log(JSON.stringify(chains, null, 2));
console.error(`${chains.length} chains in ${Date.now() - started} ms (${config.llmModel})`);
