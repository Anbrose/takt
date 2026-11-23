import { desc, eq } from 'drizzle-orm';
import type { FastifyInstance } from 'fastify';
import { routes } from '@takt/contract';
import type { Db } from '../db/client.ts';
import { notes } from '../db/schema.ts';
import { HttpError, route, type ResolveOwner } from '../http.ts';
import {
  defaultTitle,
  loadNote,
  loadSegments,
  toNote,
  toSummary,
  transcriptHash,
} from '../services/notes.ts';

export function noteRoutes(app: FastifyInstance, db: Db, owner: ResolveOwner) {
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
      .where(eq(notes.id, row.id))
      .returning();
    return full(updated!);
  });

  route(app, owner, routes.deleteNote, async ({ owner, params }) => {
    const row = await loadNote(db, owner, params.noteId);
    // note_segments go with it (ON DELETE CASCADE); audio cleanup arrives with the audio store.
    await db.delete(notes).where(eq(notes.id, row.id));
    return { id: row.id };
  });
}
