import { sql } from 'drizzle-orm';
import {
  check,
  doublePrecision,
  index,
  integer,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid,
  type AnyPgColumn,
} from 'drizzle-orm/pg-core';

export const projects = pgTable(
  'projects',
  {
    id: uuid().primaryKey().defaultRandom(),
    /** Single-user for now; every query is scoped by owner so accounts can be added without a migration. */
    ownerId: text('owner_id').notNull(),
    name: text().notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('projects_owner_idx').on(t.ownerId, t.createdAt)],
);

/**
 * Adjacency-list tree. Each project has exactly one root task (parent_id null) whose children
 * are the first visible level. Sibling order = `position` (0..n-1), rewritten in full on save.
 */
export const tasks = pgTable(
  'tasks',
  {
    id: uuid().primaryKey().defaultRandom(),
    projectId: uuid('project_id')
      .notNull()
      .references(() => projects.id, { onDelete: 'cascade' }),
    parentId: uuid('parent_id').references((): AnyPgColumn => tasks.id, { onDelete: 'cascade' }),
    position: integer().notNull(),
    name: text().notNull(),
    short: text().notNull(),
    place: text().notNull().default(''),
    /** Full postal address from the place search; with `place` it identifies the spot for map apps. */
    address: text().notNull().default(''),
    lat: doublePrecision(),
    lng: doublePrecision(),
    completedAt: timestamp('completed_at', { withTimezone: true }),
    /** Optimistic-concurrency version of this task's child list (membership + order). */
    childrenVersion: integer('children_version').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('tasks_parent_idx').on(t.parentId, t.position),
    index('tasks_project_idx').on(t.projectId),
    uniqueIndex('tasks_one_root_per_project')
      .on(t.projectId)
      .where(sql`${t.parentId} is null`),
    check('tasks_geo_pair', sql`(${t.lat} is null) = (${t.lng} is null)`),
  ],
);

export const prerequisites = pgTable(
  'prerequisites',
  {
    id: uuid().primaryKey().defaultRandom(),
    taskId: uuid('task_id')
      .notNull()
      .references(() => tasks.id, { onDelete: 'cascade' }),
    position: integer().notNull(),
    action: text().notNull(),
    urgency: text({ enum: ['early', 'before', 'onsite'] }).notNull(),
    doneAt: timestamp('done_at', { withTimezone: true }),
  },
  (t) => [
    index('prerequisites_task_idx').on(t.taskId, t.position),
    check('prerequisites_urgency', sql`${t.urgency} in ('early', 'before', 'onsite')`),
  ],
);
