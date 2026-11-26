import { describe, expect, it } from 'vitest';
import { chunkLines, renderTranscript } from '../src/llm/extractor.ts';

const line = (text: string, speaker: string | null = 'S1', startMs = 0, endMs = 1000) => ({
  startMs,
  endMs,
  text,
  speaker,
});

describe('chunkLines', () => {
  it('keeps order and never splits a line', () => {
    const lines = Array.from({ length: 10 }, (_, i) => line(`line-${i}-${'x'.repeat(50)}`));
    const chunks = chunkLines(lines, 300);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.flat()).toEqual(lines);
    for (const c of chunks) expect(c.length).toBeGreaterThan(0);
  });

  it('puts an oversized line in its own chunk and returns nothing for no lines', () => {
    const big = line('x'.repeat(500));
    expect(chunkLines([line('a'), big, line('b')], 100)).toEqual([[line('a')], [big], [line('b')]]);
    expect(chunkLines([])).toEqual([]);
  });
});

describe('renderTranscript', () => {
  it('uses speaker names, falls back to the id, and omits the prefix when speaker is null', () => {
    const out = renderTranscript(
      [
        line('去京都', 'S1', 192_000, 198_000),
        line('好的', 'S9', 199_000, 200_000),
        line('嗯', null, 201_000, 202_000),
      ],
      [{ id: 'S1', name: '小林' }],
    );
    expect(out).toBe('[03:12–03:18] 小林: 去京都\n[03:19–03:20] S9: 好的\n[03:21–03:22] 嗯');
  });
});
