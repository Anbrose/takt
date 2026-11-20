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
  return nullables(rest) as Record<string, unknown>;
}

type Json = Record<string, unknown>;
const isNullSchema = (s: unknown) => (s as Json)?.type === 'null' && Object.keys(s as Json).length === 1;

/**
 * Zod emits `anyOf: [X, { type: 'null' }]` for nullable fields; swift-openapi-generator skips
 * `{ type: 'null' }`. Rewrite to forms it understands:
 *  - inline schema with a `type` → `type: [X.type, 'null']`
 *  - `$ref` → the bare ref, and the property is dropped from `required` (Swift: Optional; a JSON
 *    null decodes to nil). The server still always sends the key.
 */
function nullables(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(nullables);
  if (!node || typeof node !== 'object') return node;
  const out: Json = {};
  for (const [k, v] of Object.entries(node as Json)) out[k] = nullables(v);

  const props = out.properties as Json | undefined;
  if (props && typeof props === 'object') {
    const loosen = new Set<string>();
    for (const [name, p] of Object.entries(props)) {
      const anyOf = (p as Json).anyOf as unknown[] | undefined;
      if (!anyOf || anyOf.length !== 2 || !anyOf.some(isNullSchema)) continue;
      const other = anyOf.find((s) => !isNullSchema(s)) as Json;
      const { anyOf: _drop, ...meta } = p as Json;
      void _drop;
      if (typeof other.$ref === 'string') {
        props[name] = { ...meta, $ref: other.$ref };
        loosen.add(name);
      } else if (typeof other.type === 'string') {
        props[name] = { ...meta, ...other, type: [other.type, 'null'] };
      }
    }
    if (loosen.size && Array.isArray(out.required)) {
      out.required = (out.required as string[]).filter((r) => !loosen.has(r));
    }
  }
  return out;
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
