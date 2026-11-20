import type { z } from 'zod';
import * as S from './schemas.ts';

export interface RouteDef {
  operationId: string;
  method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  /** OpenAPI style: /tasks/{taskId}/children */
  path: string;
  summary: string;
  params?: z.ZodObject;
  query?: z.ZodObject;
  body?: z.ZodType;
  response: z.ZodType;
  status: 200 | 201;
  errors: readonly number[];
}

/** Single source of truth: the API registers these, openapi.json is generated from them. */
export const routes = {
  listProjects: {
    operationId: 'listProjects',
    method: 'GET',
    path: '/projects',
    summary: 'Projects of the current user',
    response: S.ProjectList,
    status: 200,
    errors: [],
  },
  createProject: {
    operationId: 'createProject',
    method: 'POST',
    path: '/projects',
    summary: 'Create a project (with its hidden root task)',
    body: S.CreateProject,
    response: S.Project,
    status: 201,
    errors: [400],
  },
  getProject: {
    operationId: 'getProject',
    method: 'GET',
    path: '/projects/{projectId}',
    summary: 'One project',
    params: S.ProjectParams,
    response: S.Project,
    status: 200,
    errors: [404],
  },
  getLevel: {
    operationId: 'getLevel',
    method: 'GET',
    path: '/tasks/{taskId}/children',
    summary: 'One level: the task, its breadcrumb and its children in order',
    params: S.TaskParams,
    response: S.Level,
    status: 200,
    errors: [404],
  },
  createTask: {
    operationId: 'createTask',
    method: 'POST',
    path: '/tasks/{taskId}/children',
    summary: '新建: append a task at the end of this level',
    params: S.TaskParams,
    body: S.CreateTask,
    response: S.TaskSummary,
    status: 201,
    errors: [400, 404],
  },
  deleteTask: {
    operationId: 'deleteTask',
    method: 'DELETE',
    path: '/tasks/{taskId}',
    summary: '左滑删除: delete a task (and everything under it); returns its parent level',
    params: S.TaskParams,
    response: S.Level,
    status: 200,
    errors: [400, 404],
  },
  reorderLevel: {
    operationId: 'reorderLevel',
    method: 'PUT',
    path: '/tasks/{taskId}/children/order',
    summary: '保存: replace the order of this level',
    params: S.TaskParams,
    body: S.ReorderLevel,
    response: S.Level,
    status: 200,
    errors: [400, 404, 409],
  },
  getLevelPlan: {
    operationId: 'getLevelPlan',
    method: 'GET',
    path: '/tasks/{taskId}/plan',
    summary: 'Route summary and 准备清单 for this level (optionally a selected scope)',
    params: S.TaskParams,
    query: S.PlanQuery,
    response: S.LevelPlan,
    status: 200,
    errors: [400, 404],
  },
  updatePrerequisite: {
    operationId: 'updatePrerequisite',
    method: 'PATCH',
    path: '/prerequisites/{prerequisiteId}',
    summary: 'Mark a prerequisite done / not done',
    params: S.PrerequisiteParams,
    body: S.UpdatePrerequisite,
    response: S.Prerequisite,
    status: 200,
    errors: [400, 404],
  },
  getRun: {
    operationId: 'getRun',
    method: 'GET',
    path: '/projects/{projectId}/run',
    summary: '进行中: current / next / later',
    params: S.ProjectParams,
    response: S.RunState,
    status: 200,
    errors: [404],
  },
  completeTask: {
    operationId: 'completeTask',
    method: 'POST',
    path: '/tasks/{taskId}/complete',
    summary: '完成: mark a leaf task done',
    params: S.TaskParams,
    response: S.RunState,
    status: 200,
    errors: [404, 409],
  },
  reopenTask: {
    operationId: 'reopenTask',
    method: 'DELETE',
    path: '/tasks/{taskId}/complete',
    summary: '上一项: mark a leaf task not done',
    params: S.TaskParams,
    response: S.RunState,
    status: 200,
    errors: [404, 409],
  },
  resetRun: {
    operationId: 'resetRun',
    method: 'POST',
    path: '/projects/{projectId}/run/reset',
    summary: 'Start the run over (clears task completion, keeps prerequisites)',
    params: S.ProjectParams,
    response: S.RunState,
    status: 200,
    errors: [404],
  },
} as const satisfies Record<string, RouteDef>;

export type Routes = typeof routes;
