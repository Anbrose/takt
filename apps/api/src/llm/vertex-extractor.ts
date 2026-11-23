import { GoogleGenAI } from '@google/genai';
import { z } from 'zod';
import {
  DraftSchema,
  SYSTEM_PROMPT,
  renderTranscript,
  type DraftChain,
  type ExtractInput,
  type Extractor,
} from './extractor.ts';

export interface VertexOptions {
  project: string;
  location: string;
  model: string;
}

/** Gemini on Vertex AI. Kept in one file so the SDK/provider can be swapped. */
export class VertexExtractor implements Extractor {
  private readonly ai: GoogleGenAI;
  constructor(private readonly opts: VertexOptions) {
    this.ai = new GoogleGenAI({ vertexai: true, project: opts.project, location: opts.location });
  }

  async extract(input: ExtractInput): Promise<DraftChain[]> {
    const res = await this.ai.models.generateContent({
      model: this.opts.model,
      contents: renderTranscript(input.lines, input.speakers),
      config: {
        systemInstruction: SYSTEM_PROMPT,
        temperature: 0,
        responseMimeType: 'application/json',
        responseJsonSchema: z.toJSONSchema(DraftSchema, { target: 'draft-7' }),
      },
    });
    return DraftSchema.parse(JSON.parse(res.text ?? '')).chains;
  }
}
