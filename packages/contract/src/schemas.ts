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
    address: z.string(),
    lat: Lat.nullable(),
    lng: Lng.nullable(),
    completed: z.boolean(),
    prerequisites: z.array(Prerequisite),
    childCount: z.int().min(0),
  })
  .meta({
    id: 'TaskSummary',
    description:
      'One row of a level list. lat/lng null = 未定位. place + address identify the spot for map apps.',
  });

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

export const UpdateProject = z
  .object({ name: z.string().trim().min(1).max(200) })
  .meta({ id: 'UpdateProject' });

export const DeletedProject = z.object({ id: z.uuid() }).meta({ id: 'DeletedProject' });

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
    address: z.string().trim().max(300).optional(),
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
    address: z.string(),
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

// Notes (录音笔记): recording, on-device transcript, task-chain extraction.
const Ms = z.int().min(0);

export const TranscriptLine = z
  .object({ startMs: Ms, endMs: Ms, text: z.string().max(5000), speaker: z.string().nullable() })
  .meta({ id: 'TranscriptLine', description: 'speaker is a Speaker id, null = unlabelled.' });

export const Speaker = z
  .object({ id: z.string().min(1).max(20), name: z.string().trim().min(1).max(40) })
  .meta({ id: 'Speaker' });

export const Quote = z.object({ startMs: Ms, endMs: Ms }).meta({
  id: 'Quote',
  description: 'The transcript span a step was drawn from.',
});

export const ChainStep = z
  .object({
    id: z.uuid(),
    name: z.string().trim().min(1).max(200),
    place: z.string().max(200).nullable(),
    quote: Quote,
  })
  .meta({ id: 'ChainStep' });

export const Chain = z
  .object({
    id: z.uuid(),
    name: z.string().trim().min(1).max(200),
    steps: z.array(ChainStep).min(1).max(100),
  })
  .meta({ id: 'Chain' });

export const Extraction = z.object({ version: Ms, chains: z.array(Chain).max(50) }).meta({
  id: 'Extraction',
  description: 'The AI draft. version increases on every change; stale writes get 409.',
});

export const ImportedStep = z
  .object({
    stepId: z.uuid(),
    chainName: z.string(),
    stepName: z.string(),
    taskId: z.uuid(),
    parentTaskId: z.uuid(),
    importedAt: z.iso.datetime(),
  })
  .meta({ id: 'ImportedStep' });

export const NoteSegment = z
  .object({ index: z.int().min(0).max(999), durationMs: Ms, uploaded: z.boolean() })
  .meta({ id: 'NoteSegment' });

export const NoteSummary = z
  .object({
    id: z.uuid(),
    title: z.string(),
    locale: z.string(),
    durationMs: Ms,
    createdAt: z.iso.datetime(),
    hasTranscript: z.boolean(),
    chainCount: z.int().min(0),
    importedCount: z.int().min(0),
  })
  .meta({ id: 'NoteSummary' });

export const Note = NoteSummary.extend({
  transcript: z.array(TranscriptLine),
  speakers: z.array(Speaker),
  segments: z.array(NoteSegment),
  extraction: Extraction,
  imported: z.array(ImportedStep),
}).meta({ id: 'Note' });

export const NoteList = z.object({ notes: z.array(NoteSummary) }).meta({ id: 'NoteList' });

export const CreateNote = z
  .object({
    id: z.uuid(),
    title: z.string().trim().min(1).max(100).optional(),
    locale: z.string().min(2).max(20),
    createdAt: z.iso.datetime().optional(),
  })
  .meta({
    id: 'CreateNote',
    description: 'Client-chosen id makes a retried create idempotent.',
  });

export const UpdateNote = z
  .object({
    title: z.string().trim().min(1).max(100).optional(),
    durationMs: Ms.optional(),
    transcript: z.array(TranscriptLine).max(20000).optional(),
    speakers: z.array(Speaker).max(20).optional(),
  })
  .meta({ id: 'UpdateNote' });

export const UpdateExtraction = z.object({ version: Ms, chains: z.array(Chain).max(50) }).meta({
  id: 'UpdateExtraction',
  description: 'version is the one the edit was based on; mismatch = 409.',
});

export const CompleteSegment = z.object({ durationMs: Ms }).meta({ id: 'CompleteSegment' });

export const UploadTicket = z
  .object({ uploadUrl: z.url(), expiresAt: z.iso.datetime() })
  .meta({ id: 'UploadTicket', description: 'Signed URL; the phone PUTs the audio straight to storage.' });

export const AudioUrls = z
  .object({
    segments: z.array(
      z.object({ index: z.int().min(0), durationMs: Ms, url: z.url(), expiresAt: z.iso.datetime() }),
    ),
  })
  .meta({ id: 'AudioUrls' });

export const PickedPlace = z
  .object({ place: z.string().max(200), address: z.string().max(300), lat: Lat, lng: Lng })
  .meta({ id: 'PickedPlace' });

export const ImportPick = z
  .object({
    chainId: z.uuid(),
    stepIds: z.array(z.uuid()).min(1).max(100),
    places: z.record(z.uuid(), PickedPlace).optional(),
  })
  .meta({ id: 'ImportPick', description: 'places is keyed by step id.' });

export const ImportNote = z
  .object({ parentTaskId: z.uuid(), picks: z.array(ImportPick).min(1).max(50) })
  .meta({ id: 'ImportNote' });

export const ImportResult = z.object({ level: Level, note: Note }).meta({ id: 'ImportResult' });

export const DeletedNote = z.object({ id: z.uuid() }).meta({ id: 'DeletedNote' });

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
export const NoteParams = z.object({ noteId: z.uuid() });
export const SegmentParams = z.object({
  noteId: z.uuid(),
  index: z.coerce.number().int().min(0).max(999),
});
