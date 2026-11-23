import { and, asc, desc, eq, isNotNull } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { routes } from '@takt/contract';
import type { Db } from '../db/client.ts';
import { noteSegments, notes } from '../db/schema.ts';
import { HttpError, route, type ResolveOwner } from '../http.ts';
import {
  defaultTitle,
  loadNote,
  loadSegments,
  toNote,
  toSummary,
  transcriptHash,
} from '../services/notes.ts';
import { notePrefix, segmentObject, type AudioStore } from '../storage/audio-store.ts';

const READ_URL_TTL_SECONDS = 3600;

export function noteRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner, audio: AudioStore) {
  const full = async (row: Awaited<ReturnType<typeof loadNote>>) =>
    toNote(row, await loadSegments(db, row.id));

  route(app, owner, routes.listNotes, async ({ owner }) => {
    const rows = await db
      .select()
      .from(notes)
      .where(eq(notes.ownerId, owner))
      .orderBy(desc(notes.createdAt), desc(notes.id));
    return { notes: rows.map(toSummary) };
  });

  route(app, owner, routes.createNote, async ({ owner, body }) => {
    const createdAt = body.createdAt ? new Date(body.createdAt) : new Date();
    await db
      .insert(notes)
      .values({
        id: body.id,
        ownerId: owner,
        title: body.title ?? defaultTitle(createdAt),
        locale: body.locale,
        createdAt,
      })
      .onConflictDoNothing({ target: notes.id });
    const [row] = await db.select().from(notes).where(eq(notes.id, body.id));
    if (row!.ownerId !== owner) throw new HttpError(409, 'note_id_taken', 'Note id is already in use');
    return full(row!);
  });

  route(app, owner, routes.getNote, async ({ owner, params }) =>
    full(await loadNote(db, owner, params.noteId)),
  );

  route(app, owner, routes.updateNote, async ({ owner, params, body }) => {
    const row = await loadNote(db, owner, params.noteId);
    const [updated] = await db
      .update(notes)
      .set({
        ...(body.title !== undefined && { title: body.title }),
        ...(body.durationMs !== undefined && { durationMs: body.durationMs }),
        ...(body.speakers !== undefined && { speakers: body.speakers }),
        ...(body.transcript !== undefined && {
          transcript: body.transcript,
          transcriptHash: transcriptHash(body.transcript),
        }),
        updatedAt: new Date(),
      })
      .where(and(eq(notes.id, row.id), eq(notes.ownerId, owner)))
      .returning();
    return full(updated!);
  });

  route(app, owner, routes.deleteNote, async ({ owner, params }) => {
    const row = await loadNote(db, owner, params.noteId);
    // note_segments go with it (ON DELETE CASCADE).
    await db.delete(notes).where(and(eq(notes.id, row.id), eq(notes.ownerId, owner)));
    await audio.deletePrefix(notePrefix(owner, row.id));
    return { id: row.id };
  });

  route(app, owner, routes.uploadSegment, async ({ owner, params }) => {
    const row = await loadNote(db, owner, params.noteId);
    const ticket = await audio.createUpload(segmentObject(owner, row.id, params.index), 'audio/mp4');
    return { uploadUrl: ticket.uploadUrl, expiresAt: ticket.expiresAt.toISOString() };
  });

  route(app, owner, routes.completeSegment, async ({ owner, params, body }) => {
    const row = await loadNote(db, owner, params.noteId);
    if (!(await audio.stat(segmentObject(owner, row.id, params.index)))) {
      throw new HttpError(409, 'segment_missing', 'Segment audio has not been uploaded');
    }
    const uploadedAt = new Date();
    const updated = await db.transaction(async (tx) => {
      await tx
        .insert(noteSegments)
        .values({ noteId: row.id, index: params.index, durationMs: body.durationMs, uploadedAt })
        .onConflictDoUpdate({
          target: [noteSegments.noteId, noteSegments.index],
          set: { durationMs: body.durationMs, uploadedAt },
        });
      const segments = await loadSegments(tx, row.id);
      const total = segments.reduce((sum, s) => sum + s.durationMs, 0);
      const [n] = await tx
        .update(notes)
        .set({ durationMs: total, updatedAt: uploadedAt })
        .where(and(eq(notes.id, row.id), eq(notes.ownerId, owner)))
        .returning();
      return { note: n!, segments };
    });
    return toNote(updated.note, updated.segments);
  });

  route(app, owner, routes.noteAudio, async ({ owner, params }) => {
    const row = await loadNote(db, owner, params.noteId);
    const uploaded = await db
      .select()
      .from(noteSegments)
      .where(and(eq(noteSegments.noteId, row.id), isNotNull(noteSegments.uploadedAt)))
      .orderBy(asc(noteSegments.index));
    const segments = await Promise.all(
      uploaded.map(async (s) => {
        const read = await audio.readUrl(segmentObject(owner, row.id, s.index), READ_URL_TTL_SECONDS);
        return {
          index: s.index,
          durationMs: s.durationMs,
          url: read.url,
          expiresAt: read.expiresAt.toISOString(),
        };
      }),
    );
    return { segments };
  });
}
