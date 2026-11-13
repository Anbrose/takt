import { z } from 'zod';
import { URGENCIES } from '@takt/core';

// Every schema with `.meta({ id })` becomes a named component in openapi.json (and a named Swift type).

export const Urgency = z.enum(URGENCIES).meta({
  id: 'Urgency',
  description: 'early = 尽早订（限量）, before = 行前订, onsite = 现场办',
});

const Lat = z.number().min(-90).max(90);
const Lng = z.number().min(-180).max(180);

export const Prerequisite = z
  .object({ id: z.uuid(), action: z.string(), urgency: Urgency, done: z.boolean() })
  .meta({ id: 'Prerequisite' });

export const TaskSummary = z
  .object({
    id: z.uuid(),
    name: z.string(),
    short: z.string(),
    place: z.string(),
    lat: Lat.nullable(),
    lng: Lng.nullable(),
    completed: z.boolean(),
    prerequisites: z.array(Prerequisite),
    childCount: z.int().min(0),
  })
  .meta({ id: 'TaskSummary', description: 'One row of a level list. lat/lng null = 未定位.' });

export const Crumb = z.object({ id: z.uuid(), name: z.string() }).meta({ id: 'Crumb' });

export const Project = z
  .object({ id: z.uuid(), name: z.string(), rootTaskId: z.uuid(), createdAt: z.iso.datetime() })
  .meta({
    id: 'Project',
    description: 'rootTaskId is the hidden top task whose children are the first level.',
  });

export const ProjectList = z.object({ projects: z.array(Project) }).meta({ id: 'ProjectList' });

export const CreateProject = z
  .object({ name: z.string().trim().min(1).max(200) })
  .meta({ id: 'CreateProject' });

export const Level = z
  .object({
    projectId: z.uuid(),
    task: Crumb,
    /** Root first, ending with `task`. */
    breadcrumb: z.array(Crumb),
    /** Bumped on every change to this level's membership or order. Send it back when saving an order. */
    version: z.int().min(0),
    children: z.array(TaskSummary),
  })
  .meta({ id: 'Level', description: 'One level of the task tree, children in execution order.' });

export const NewPrerequisite = z
  .object({ action: z.string().trim().min(1).max(200), urgency: Urgency.optional() })
  .meta({ id: 'NewPrerequisite', description: 'urgency defaults to before (行前订).' });

export const CreateTask = z
  .object({
    name: z.string().trim().min(1).max(200),
    short: z.string().trim().min(1).max(40).optional(),
    place: z.string().trim().max(200).optional(),
    lat: Lat.nullable().optional(),
    lng: Lng.nullable().optional(),
    prerequisites: z.array(NewPrerequisite).max(50).optional(),
  })
  .refine((b) => (b.lat == null) === (b.lng == null), { message: 'lat and lng must be given together' })
  .meta({ id: 'CreateTask', description: 'Appended at the end of the level. short defaults to name.' });

export const ReorderLevel = z
  .object({ ids: z.array(z.uuid()).max(500), version: z.int().min(0) })
  .meta({ id: 'ReorderLevel', description: 'The complete new order of the level (same ids, any order).' });

export const UpdatePrerequisite = z.object({ done: z.boolean() }).meta({ id: 'UpdatePrerequisite' });

export const Objective = z.enum(['distance', 'time']).meta({ id: 'Objective' });
export const Travel = z.enum(['walk', 'transit', 'drive']).meta({ id: 'Travel' });

export const Leg = z
  .object({
    taskId: z.uuid(),
    kind: z.enum(['start', 'leg', 'unlocated', 'outOfScope']),
    /** Set only for kind = leg: km from the previous located, in-scope task. */
    km: z.number().nullable(),
  })
  .meta({ id: 'Leg' });

export const TaskPrerequisite = z
  .object({ taskId: z.uuid(), taskName: z.string(), prerequisite: Prerequisite })
  .meta({ id: 'TaskPrerequisite' });

export const LevelPlan = z
  .object({
    taskId: z.uuid(),
    objective: Objective,
    travel: Travel,
    scopeIds: z.array(z.uuid()),
    route: z.object({
      legs: z.array(Leg),
      totalKm: z.number().nullable(),
      bestKm: z.number().nullable(),
      extraKm: z.number(),
      status: z.enum(['needMore', 'optimal', 'detour']),
      /** Full order of the level after 重排; null unless status = detour. Save it with PUT …/order. */
      optimizedOrder: z.array(z.uuid()).nullable(),
    }),
    prep: z.object({
      items: z.array(TaskPrerequisite),
      remaining: z.int().min(0),
      noPrepCount: z.int().min(0),
    }),
  })
  .meta({
    id: 'LevelPlan',
    description:
      'Map + 准备清单 for one level and scope. Distances are straight-line until real routing lands; objective/travel are accepted but do not change results yet.',
  });

export const RunTask = z
  .object({
    id: z.uuid(),
    name: z.string(),
    place: z.string(),
    lat: Lat.nullable(),
    lng: Lng.nullable(),
    prerequisites: z.array(Prerequisite),
  })
  .meta({ id: 'RunTask' });

export const RunStep = z
  .object({ task: RunTask, path: z.array(Crumb).meta({ description: 'Stages from top level to parent.' }) })
  .meta({ id: 'RunStep' });

export const NextStep = z
  .object({
    step: RunStep,
    km: z.number().nullable(),
    stage: z.object({ from: Crumb.nullable(), to: Crumb.nullable() }).nullable(),
    prerequisites: z.array(TaskPrerequisite),
  })
  .meta({
    id: 'NextStep',
    description:
      'stage is set when the next step is in a different stage; prerequisites then include every entered stage’s own.',
  });

export const RunState = z
  .object({
    projectId: z.uuid(),
    total: z.int().min(0),
    index: z.int().min(0),
    finished: z.boolean(),
    current: RunStep.nullable(),
    next: NextStep.nullable(),
    later: z.array(RunStep),
    previousTaskId: z.uuid().nullable(),
  })
  .meta({ id: 'RunState', description: '进行中: current = first incomplete leaf in plan order.' });

export const ApiError = z
  .object({ error: z.string(), message: z.string(), issues: z.array(z.unknown()).optional() })
  .meta({ id: 'ApiError' });

// Path / query parameters (flat, primitives only).
export const ProjectParams = z.object({ projectId: z.uuid() });
export const TaskParams = z.object({ taskId: z.uuid() });
export const PrerequisiteParams = z.object({ prerequisiteId: z.uuid() });
export const PlanQuery = z.object({
  scope: z
    .string()
    .optional()
    .meta({ description: 'Comma-separated child ids (勾选). Omit for the whole level.' }),
  objective: Objective.optional(),
  travel: Travel.optional(),
});
