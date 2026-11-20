import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { RouteDef } from '@takt/contract';

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly issues: unknown[] | undefined;
  constructor(status: number, code: string, message: string = code, issues?: unknown[]) {
    super(message);
    this.status = status;
    this.code = code;
    this.issues = issues;
  }
}

export const notFound = (what: string) => new HttpError(404, 'not_found', `${what} not found`);

type In<S> = S extends z.ZodType ? z.output<S> : undefined;

export interface Input<D extends RouteDef> {
  params: In<D['params']>;
  query: In<D['query']>;
  body: In<D['body']>;
  owner: string;
}

export type ResolveOwner = (req: FastifyRequest) => string;

/** Registers a contract route: validates params/query/body in, and the response out. */
export function route<D extends RouteDef>(
  app: FastifyInstance,
  resolveOwner: ResolveOwner,
  def: D,
  handler: (input: Input<D>) => Promise<z.input<D['response']>>,
) {
  app.route({
    method: def.method,
    url: def.path.replace(/\{(\w+)\}/g, ':$1'),
    handler: async (req, reply) => {
      const input = {
        params: def.params ? parse(def.params, req.params) : undefined,
        query: def.query ? parse(def.query, req.query) : undefined,
        body: def.body ? parse(def.body, req.body ?? {}) : undefined,
        owner: resolveOwner(req),
      } as Input<D>;
      const out = await handler(input);
      const checked = def.response.safeParse(out);
      if (!checked.success) {
        req.log.error({ issues: checked.error.issues, route: def.operationId }, 'response violates contract');
        throw new HttpError(500, 'internal', 'Response failed contract validation');
      }
      return reply.status(def.status).send(checked.data);
    },
  });
}

function parse<S extends z.ZodType>(schema: S, value: unknown): z.output<S> {
  const r = schema.safeParse(value);
  if (!r.success) throw new HttpError(400, 'validation', 'Invalid request', r.error.issues);
  return r.data;
}

export function installErrorHandler(app: FastifyInstance) {
  app.setErrorHandler((err: Error & { statusCode?: number }, req, reply) => {
    if (err instanceof HttpError) {
      if (err.status >= 500) req.log.error(err);
      return reply.status(err.status).send({
        error: err.code,
        message: err.message,
        ...(err.issues ? { issues: err.issues } : {}),
      });
    }
    if (err.statusCode && err.statusCode < 500) {
      return reply.status(err.statusCode).send({ error: 'bad_request', message: err.message });
    }
    req.log.error(err);
    return reply.status(500).send({ error: 'internal', message: 'Internal error' });
  });
  app.setNotFoundHandler((req, reply) =>
    reply.status(404).send({ error: 'not_found', message: `No route ${req.method} ${req.url}` }),
  );
}
