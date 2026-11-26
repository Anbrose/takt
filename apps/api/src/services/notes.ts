import { createHash } from 'node:crypto';
import { and, asc, eq } from 'drizzle-orm';
import type { z } from 'zod';
import type { Note, NoteSummary, TranscriptLine } from '@takt/contract';
import type { Db } from '../db/client.ts';
import { noteSegments, notes } from '../db/schema.ts';
import { notFound } from '../http.ts';

export type NoteRow = typeof notes.$inferSelect;
export type NoteSegmentRow = typeof noteSegments.$inferSelect;

/** The note, or 404 when it does not exist or belongs to someone else. */
export async function loadNote(db: Db, owner: string, id: string): Promise<NoteRow> {
  const [row] = await db
    .select()
    .from(notes)
    .where(and(eq(notes.id, id), eq(notes.ownerId, owner)));
  if (!row) throw notFound('Note');
  return row;
}

export function loadSegments(db: Db, noteId: string): Promise<NoteSegmentRow[]> {
  return db
    .select()
    .from(noteSegments)
    .where(eq(noteSegments.noteId, noteId))
    .orderBy(asc(noteSegments.index));
}

export function toSummary(row: NoteRow): z.input<typeof NoteSummary> {
  return {
    id: row.id,
    title: row.title,
    locale: row.locale,
    durationMs: row.durationMs,
    createdAt: row.createdAt.toISOString(),
    hasTranscript: row.transcript.length > 0,
    chainCount: row.extraction.chains.length,
    importedCount: row.imported.length,
  };
}

export function toNote(row: NoteRow, segments: NoteSegmentRow[]): z.input<typeof Note> {
  return {
    ...toSummary(row),
    transcript: row.transcript,
    speakers: row.speakers,
    segments: segments.map((s) => ({
      index: s.index,
      durationMs: s.durationMs,
      uploaded: s.uploadedAt !== null,
    })),
    extraction: { version: row.extractionVersion, chains: row.extraction.chains },
    imported: row.imported,
  };
}

export const transcriptHash = (lines: z.infer<typeof TranscriptLine>[]): string =>
  createHash('sha256').update(JSON.stringify(lines)).digest('hex');

/** `YYYY-MM-DD HH:mm` in UTC. */
export const defaultTitle = (at: Date): string => at.toISOString().slice(0, 16).replace('T', ' ');
