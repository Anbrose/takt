# TAKT

规划每一步。把一件事拆成有序的任务流，执行时告诉你现在在哪、接下来做什么。

设计交接：[`design/takt-handoff/HANDOFF.md`](design/takt-handoff/HANDOFF.md) · 技术决定：[`docs/decisions.md`](docs/decisions.md)

## 目录

```
apps/api/            后端：Fastify + Drizzle（Postgres / PGlite）
apps/ios/            iOS 客户端（SwiftUI，下一阶段）
apps/web/            前端页面（React + TS，后续阶段）
packages/core/       领域类型 + 纯数据规则：距离、最短路线、准备清单、进行中展开
packages/contract/   API 请求/响应结构（Zod）→ openapi.json（iOS 客户端从它生成）
packages/fixtures/   示例数据 + 规则测试用例（由原型 logic.js 计算得出；TS 和 Swift 共用）
design/              设计交接文件（只读）
```

## 本地开发

需要 Node ≥ 22 和 corepack（pnpm 版本固定在 `package.json` 的 `packageManager` 字段）。

```sh
corepack enable          # 一次即可
pnpm install
pnpm seed                # 导入「日本旅行」示例数据（apps/api/.data/pglite）
pnpm dev                 # http://127.0.0.1:3000
```

默认使用内嵌的 PGlite，不需要装数据库。要连真实 Postgres：

```sh
docker compose up -d     # 或者用任意 Postgres / Neon
DATABASE_URL=postgres://takt:takt@localhost:5433/takt pnpm seed
DATABASE_URL=postgres://takt:takt@localhost:5433/takt pnpm dev
```

服务启动时会自动执行迁移。改了 `apps/api/src/db/schema.ts` 之后，运行 `pnpm --filter @takt/api db:generate` 生成新的迁移文件。

## 检查

```sh
pnpm test        # core 规则 + 原型标准答案、openapi.json 是否最新、API 集成测试
pnpm typecheck
pnpm lint
pnpm openapi     # 改了 contract 之后重新生成 packages/contract/openapi.json
```

## API 一览

|                                                                                               |                                                     |
| --------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `GET/POST /projects`, `GET /projects/{id}`                                                    | Project 列表、新建、详情（`rootTaskId` 就是第一级） |
| `GET /tasks/{id}/children`                                                                    | 读取一级任务：面包屑、`version`、按顺序排列的子任务 |
| `POST /tasks/{id}/children`                                                                   | 新建：追加到这一级末尾                              |
| `PUT /tasks/{id}/children/order`                                                              | 保存顺序：`{ ids, version }`                        |
| `GET /tasks/{id}/plan?scope=&objective=&travel=`                                              | 地图距离 / 多绕 / 重排顺序 + 准备清单               |
| `PATCH /prerequisites/{id}`                                                                   | 勾选前置条件完成 / 取消                             |
| `GET /projects/{id}/run`, `POST/DELETE /tasks/{id}/complete`, `POST /projects/{id}/run/reset` | 进行中：读取当前状态、完成、上一项、重新开始        |

完整定义见 `packages/contract/openapi.json`。
