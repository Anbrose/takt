import { z } from 'zod';
import { routes, type RouteDef } from './routes.ts';
import './schemas.ts';

const ref = (id: string) => ({ $ref: `#/components/schemas/${id}` });

function idOf(schema: z.ZodType): string {
  const id = z.globalRegistry.get(schema)?.id;
  if (!id) throw new Error('Request/response schemas must be registered with .meta({ id })');
  return id;
}

function clean(s: Record<string, unknown>) {
  const rest = { ...s };
  delete rest.$schema;
  delete rest.$id;
  return rest;
}

function parameters(where: 'path' | 'query', obj: z.ZodObject | undefined) {
  if (!obj) return [];
  return Object.entries(obj.shape).map(([name, field]) => {
    const f = field as z.ZodType;
    const inner = f instanceof z.ZodOptional ? (f.unwrap() as z.ZodType) : f;
    const registered = z.globalRegistry.get(inner)?.id;
    const json = registered
      ? { ...ref(registered), description: z.globalRegistry.get(f)?.description }
      : clean(z.toJSONSchema(f, { unrepresentable: 'any' }) as Record<string, unknown>);
    const { description, ...schema } = json as Record<string, unknown>;
    return {
      name,
      in: where,
      required: where === 'path' || !f.safeParse(undefined).success,
      ...(description ? { description } : {}),
      schema,
    };
  });
}

function operation(r: RouteDef) {
  const responses: Record<string, unknown> = {
    [r.status]: { description: 'OK', content: { 'application/json': { schema: ref(idOf(r.response)) } } },
  };
  for (const code of r.errors) {
    responses[code] = { description: 'Error', content: { 'application/json': { schema: ref('ApiError') } } };
  }
  return {
    operationId: r.operationId,
    summary: r.summary,
    parameters: [...parameters('path', r.params), ...parameters('query', r.query)],
    ...(r.body
      ? { requestBody: { required: true, content: { 'application/json': { schema: ref(idOf(r.body)) } } } }
      : {}),
    responses,
  };
}

export function buildOpenApi() {
  const { schemas } = z.toJSONSchema(z.globalRegistry, {
    uri: (id) => `#/components/schemas/${id}`,
    unrepresentable: 'any',
  });
  const components = Object.fromEntries(
    Object.entries(schemas)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([id, s]) => [id, clean(s as Record<string, unknown>)]),
  );
  const paths: Record<string, Record<string, unknown>> = {};
  for (const r of Object.values(routes) as RouteDef[]) {
    (paths[r.path] ??= {})[r.method.toLowerCase()] = operation(r);
  }
  return {
    openapi: '3.1.0',
    info: { title: 'TAKT API', version: '0.1.0' },
    servers: [{ url: 'http://localhost:3000' }],
    paths,
    components: { schemas: components },
  };
}
