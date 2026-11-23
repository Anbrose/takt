import { z } from 'zod';
import type { Speaker, TranscriptLine } from '@takt/contract';

type Line = z.infer<typeof TranscriptLine>;
type Who = z.infer<typeof Speaker>;

export interface ExtractInput {
  locale: string;
  speakers: Who[];
  lines: Line[];
}

export interface DraftChain {
  name: string;
  steps: { name: string; place: string | null; quote: { startMs: number; endMs: number } }[];
}

export interface Extractor {
  extract(input: ExtractInput): Promise<DraftChain[]>;
}

export interface ExtractLimits {
  /** Extractions per note. */
  perNote: number;
  /** LLM calls per owner per UTC month. */
  monthlyCalls: number;
}

/** Structured output the model must produce (also sent as JSON schema). */
export const DraftSchema = z.object({
  chains: z.array(
    z.object({
      name: z.string(),
      steps: z.array(
        z.object({
          name: z.string(),
          place: z.string().nullable(),
          quote: z.object({ startMs: z.number(), endMs: z.number() }),
        }),
      ),
    }),
  ),
});

export const SYSTEM_PROMPT = `你是任务整理助手。输入是一段多人对话的逐字稿，每行形如 "[mm:ss–mm:ss] 说话人: 内容"。
从中提取对话里真正说到要做的事，整理成任务链。规则：
- 只提取对话中实际说出的行动，不要编造、不要补充没说过的步骤。
- 一条链（chain）是为了同一个目标、按顺序要做的一组步骤（step）。链名概括目标。
- 步骤名（name）用简短的祈使句，语言与逐字稿一致。
- place 只在对话明确提到具体地点时填写，并结合上下文纠正语音识别错误（例如“福建造合照社”应为“伏见稻荷大社”）；否则为 null。
- quote 是支持该步骤的那几行的时间范围，单位毫秒（startMs、endMs），取自行首的时间。
- 如果没有可执行的内容，chains 返回空数组。`;

export class FakeExtractor implements Extractor {
  readonly calls: ExtractInput[] = [];
  constructor(private result: DraftChain[] | Error) {}
  async extract(input: ExtractInput): Promise<DraftChain[]> {
    this.calls.push(input);
    if (this.result instanceof Error) throw this.result;
    return structuredClone(this.result);
  }
}

const clock = (ms: number): string => {
  const s = Math.floor(ms / 1000);
  const mm = String(Math.floor(s / 60)).padStart(2, '0');
  return `${mm}:${String(s % 60).padStart(2, '0')}`;
};

/** `[03:12–03:18] 小林: …` per line; no speaker prefix when the line has none. */
export function renderTranscript(lines: Line[], speakers: Who[]): string {
  const names = new Map(speakers.map((s) => [s.id, s.name]));
  return lines
    .map((l) => {
      const who = l.speaker === null ? '' : `${names.get(l.speaker) ?? l.speaker}: `;
      return `[${clock(l.startMs)}–${clock(l.endMs)}] ${who}${l.text}`;
    })
    .join('\n');
}

/** Splits on line boundaries, keeping order; a single oversized line gets its own chunk. */
export function chunkLines(lines: Line[], maxChars = 30_000): Line[][] {
  const chunks: Line[][] = [];
  let cur: Line[] = [];
  let size = 0;
  for (const l of lines) {
    const n = l.text.length + 32;
    if (cur.length > 0 && size + n > maxChars) {
      chunks.push(cur);
      cur = [];
      size = 0;
    }
    cur.push(l);
    size += n;
  }
  if (cur.length > 0) chunks.push(cur);
  return chunks;
}
