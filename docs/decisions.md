# 技术决定

开工前定下的事（对应 `design/takt-handoff/HANDOFF.md`「开工前需要先定的事」），2026-11-13 确认。

| #   | 事项       | 决定                                                                                                                                                         |
| --- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | 后端       | Node.js（≥22）+ Fastify 5。请求/响应用 Zod 4 定义在 `packages/contract`，`openapi.json` 由它生成                                                             |
| 2   | iOS        | SwiftUI 为主，目标 iOS 17+；拖动排序先做技术验证，不够流畅就那一块改用 UIKit `UICollectionView`                                                              |
| 3   | 账号       | 先做单用户。`projects.owner_id` 已经预留，每个查询都按 owner 过滤；目前固定为 `local`                                                                        |
| 4   | 数据库     | PostgreSQL + Drizzle ORM。没有 `DATABASE_URL` 时用内嵌的 PGlite（开发和测试都用它）                                                                          |
| 5   | 地图       | iOS 用 MapKit 画地图；网页用 Google Maps JS 还是 Mapbox，到做网页时再定。~~「最短」默认按耗时~~ → 按**直线距离**（2026-11-14 改，见「地图（第四阶段）」）    |
| 6   | 路线计算   | ~~后端统一计算~~ → **iOS 端用 MapKit 计算**（2026-11-14 改）。后端 `plan` 接口仍按直线距离，作为参考实现；网页端以后需要另选一家地图服务，两端数字可能对不上 |
| 7   | AI 辅助    | 第一阶段不做。以后做成按钮形式（从模板生成 / 补全前置条件），不做对话框                                                                                      |
| 8   | 进行中进度 | 存在后端，按任务记 `completed_at`，不按下标记。当前项 = 按规划顺序第一个未完成的叶子任务                                                                     |
| 9   | 勾选范围   | 只在端上，不落库。调用 `GET /tasks/{id}/plan?scope=` 时作为参数传给后端                                                                                      |
| 10  | 紧急程度   | API 从一开始就支持；新建时界面默认「行前订」（`before`）                                                                                                     |
| 11  | 示例数据   | 日本旅行，见 `packages/fixtures/data/japan-trip.json`，用 `pnpm seed` 导入                                                                                   |

## 实现时补充的决定

- **Project 根任务**：每个 project 有一个隐藏的根任务（`parent_id` 为空），它的子任务就是第一级。这样任意一级都用同一组接口：`/tasks/{id}/children`。
- **同级顺序**：用整数 `position` 排序。保存顺序时在事务里把整列序号重写一遍，并用父任务的 `children_version` 做乐观锁：版本不对返回 409，ID 集合不对返回 400。
- **前置条件有独立 UUID**（原型用的是 `任务id:下标`，删改后会错位）。
- **最短路线**：第一项固定为起点；12 个点以内用 Held–Karp 精确求解，超过用最近邻 + 2-opt 近似（原型的穷举复杂度是 n!）。代价函数可以是非对称的，以后可以直接换成真实耗时矩阵。
- **重排**：只移动勾选范围内、并且有坐标的任务，它们重排后填回原来的位置。新顺序由 `plan` 接口返回在 `optimizedOrder` 里，端上展示后再用 `PUT …/order` 保存，保持「保存前不落库」。
- **进行中跨段**：「接下来」会列出新进入的每一层阶段自身的前置条件（从外到内），再加上下一项自己的。原型只有两层，这里推广到任意深度。
- **距离显示**：小于 100 km 保留一位小数，否则显示整数。原型会把 99.96 显示成 "100.0"，这里改成 "100"。舍入规则按 JS `toFixed`（按二进制精确值，恰好一半时进位），Swift 端要实现成一样，用 `packages/fixtures/data/cases.json` 的 `format` 用例对照。
- **`objective` / `travel`**：接口已经接收这两个参数，但在接入真实路线之前不影响结果。

## iOS（第二阶段）

- **工程结构**：逻辑和界面都放在 Swift Package `TaktKit` 里，状态逻辑可以直接在 Mac 上用 `swift test` 测试；Xcode 工程只是一个薄外壳，用文件夹同步组和本地包引用，工程文件很少需要改动。
- **API 客户端**：用 swift-openapi-generator 在构建时生成。它会跳过 `anyOf` 里的 `{type: "null"}`，所以 `packages/contract` 在导出时做一次转换：可为空的基本类型改写成 `type: [X, "null"]`；可为空的引用类型改成非必填（Swift 里对应可选值，服务端仍然总会返回这个键）。
- **日期**：服务端输出 `toISOString()`（带毫秒），客户端用 `.iso8601WithFractionalSeconds` 解析。
- **拖动排序**：用纯 SwiftUI（`DragGesture` 加上每行测得的高度）。邻近的行用动画让位，松手后由 SwiftUI 的布局动画完成 FLIP；VoiceOver 和方向键都可以调整顺序；开启「减少动态效果」后动画全部关闭。模拟器里的 XCUITest 已经覆盖了拖动、取消和保存。**手感还需要在真机上确认**，再决定要不要换成 UIKit。
- **关闭的底部栏和表单直接从视图层级中移除**，而不是挪到屏幕外，否则 VoiceOver 和 UI 测试都还能找到里面的按钮。
- **暂未做**：内置 Inter / Noto Sans SC 字体（目前用系统字体，放到第 8 步视觉阶段）；App 图标；拖到列表边缘时自动滚动；Bundle ID 暂用 `dev.takt.app`。

## 地图（第三阶段）

- **路线数据**：iOS 用 `MKDirections.calculateETA` 取每对点之间的真实里程和耗时（步行 / 公交 / 自驾）。假设来回相同，只按无序点对请求；10 个点以内请求全部点对，供 `重排` 使用，超过 10 个点只请求相邻两项。MapKit 大约每分钟允许 50 次请求，被限流时退避重试。
- **缓存**：真实结果存在 `Caches/route-costs.json`。取不到路线时（比如大阪 → 北海道没有公交）用直线距离加平均速度估算（步行 4.5、公交 30、自驾 40 km/h），估算值不写入磁盘，下次启动重新请求。
- **算法**：`TaktCore.Route` 移植了 TS 的最短路线和 `planRoute`，代价函数可以换，用原型的标准答案测试。「多绕」的阈值：距离 50 m，耗时 1 分钟。
- **`重排`**：和原型一样直接保存，不经过 `取消 / 保存`，采用乐观更新，失败时回滚。未保存的拖动期间隐藏。
- **地图模式**：卡片原地压缩成「勾选框 · 序号 · 名称 · 与上一项的距离或耗时 · 把手」，未定位的任务变淡。连线是按顺序的点状虚线，不是实际道路。进入或离开某一级时地图会关闭。默认按「耗时 · 公交」。
- **未做**：任务卡片与地图之间的共享元素过渡（第 5 步）；新建任务时的地点搜索，所以新建的任务都是「未定位」。

## 地图（第四阶段，2026-11-14）

- **不在 App 内选出行方式**：去掉「优化目标」和「出行方式」，距离、`重排` 一律按直线距离（和后端 `plan` 接口、原型一致）。`RouteMatrix` / `MKDirections.calculateETA` 整体删除，也就没有了 MapKit 每分钟约 50 次的限流问题。实际怎么走交给 Google 地图。
- **跳转 Google 地图**：用官方 Maps URL（不需要 API key、不计费）。实机测试的结论：
  - 公交模式**不支持途经点**（「could not calculate public transport directions」），所以地图下的「Google 地图」按钮按当前顺序打开整条路线，固定**自驾**；单段公交可用，留给以后「进行中」的「导航」按钮（iOS 还没有进行中模式）。
  - 只传坐标时 Google 会对到附近别的商家（环球影城变成 “Central Park”），所以传 **地点名 + 地址**；没有地址的旧数据退回坐标。
- **地址字段**：`tasks.address`（迁移 `0001_address`），`TaskSummary` / `CreateTask` / `RunTask` 都带上。示例数据补了日文地址。
- **地点联想**：新建时「地点」用 `MKLocalSearchCompleter`（免费、无 key、大陆可用），偏向当前这一级已有地点的范围。选中候选才算定位（存名称、地址、坐标）；手打的文字仍是「未定位」。手机为中文时 Apple 返回中文名，靠地址让 Google 对上——**需要真机确认**。
- **地图连线**：每段一条直线虚线 + 方向箭头，颜色沿路线由深到浅；点一个地点只突出它进出的两段，其余变灰，点地图空白处恢复。地图下面只显示总距离（界面尽量少文字）。
- **列表**：工具栏只剩通栏的「地图」；「新建」改为右下角悬浮 +；去掉「全选」（勾选本身保留）。**左滑删除**：卡片左滑，右侧滑出红色删除按钮盖住把手，一次只开一个；VoiceOver 用行上的「删除」动作。接口 `DELETE /tasks/{id}` 连同子任务一起删，返回父级，并给父级 `children_version` 加一。

## Project 列表（第五阶段，2026-11-21）

- **打开 App 先进 Project 列表**，每项只显示名字，新的在上面（服务端按 `created_at` 倒序）。点一下推入规划页；规划页最顶层左上角的返回按钮回到列表。
- **新建**：右下角圆形按钮（列表为空时换成居中的「新建」按钮），只有名称一个字段；创建后自动进入。
- **重命名 / 删除**：长按卡片弹出系统菜单。删除用系统确认框，标题「删除「名称」？」，连同整棵任务树一起删除（`ON DELETE CASCADE`），无法恢复。重命名会同步改隐藏根任务的名字。两者都是乐观更新，失败回滚并提示。
- **接口**：新增 `PATCH /projects/{id}`（重命名）、`DELETE /projects/{id}`（返回 `{id}`）。
- **推入动画**：规划页从右侧滑入，列表左移 28% 并变暗，曲线 `cubic-bezier(0.32, 0.72, 0, 1)`、420ms；推入结束后列表移出视图层级，返回前先放回去。没有用 `NavigationStack`，因为规划页有自己的标题栏，系统导航栏的样式和动画对不上画布。
- **未做**：边缘右滑返回手势；记住上次打开的 Project；网页端的 Project 列表；「减少动态效果」下其余界面仍是瞬间切换（准则要求改成淡入淡出，留待逐处审查）。

## 录音笔记（第六阶段，2026-11-24）

- **`notes` 表**：id 由客户端生成（UUID），`POST /notes` 幂等——同一个 id 重试返回 200 和同一条笔记，不会重复；别的 owner 用了同一个 id 返回 409。每个查询都按 `owner_id` 过滤。
- **录音存在 GCS**：对象路径 `notes/{ownerId}/{noteId}/{segmentIndex}.m4a`。上传用 resumable 会话 URL，读取用 1 小时有效的签名 URL（v4）。**音频不经过 API**，手机和 GCS 直连，API 只发 URL。
- **Bucket**：区域 `australia-southeast1`，统一访问控制并禁止公开访问。由 `scripts/notes-bucket.sh` 创建（需要 `GCP_PROJECT`，可重复运行），同时给 Cloud Run 默认服务账号 `roles/storage.objectAdmin`（bucket 上）和 `roles/iam.serviceAccountTokenCreator`（对自己，用于签名）。
- **`NOTES_BUCKET` 环境变量**：设置后用 GCS，没设置时用内存存储（开发和测试不需要 GCP 凭据）。`scripts/deploy-api.sh` 合入后，部署时要加 `--set-env-vars NOTES_BUCKET=<脚本最后打印的值>`。
- **任务链提取（LLM）**：默认用 Vertex AI 上的 Gemini（`@google/genai` 的 Vertex 模式，`temperature` 0，JSON schema 结构化输出），模型和区域可配置，默认 `gemini-2.5-flash` / `us-central1`。**还没有和 Claude 对比过**——对比会产生费用，等用户批准后再做；换模型或 SDK 只需改 `apps/api/src/llm/vertex-extractor.ts`。只把逐字稿文本发给模型。手动试跑：`apps/api/scripts/try-extract.ts <transcript.json>`（不在 CI 里跑）。
- **提取的限制**：未改动的逐字稿再次提取直接返回已有草稿，不调用、不计数；每条笔记最多提取 `NOTE_EXTRACT_LIMIT` 次（默认 10，超出 429 `extract_limit`）；每个 owner 每个 UTC 月最多 `LLM_MONTHLY_CALLS` 次模型调用（默认 300，超出 429 `budget_exceeded`）。长逐字稿按行切成约 3 万字的块，每块调用一次、各计一次；预算只在开始前检查，一次提取中途超出预算也会完成，不会做到一半失败。模型调用失败返回 502 `llm_failed`，只计已经发出的调用。
- **提取相关环境变量**：`LLM_PROVIDER`（`fake` 默认，返回空草稿，启动时打日志；`vertex`）、`VERTEX_PROJECT`、`VERTEX_LOCATION`、`LLM_MODEL`、`NOTE_EXTRACT_LIMIT`、`LLM_MONTHLY_CALLS`。

## 设计流程

- 设计的唯一来源是 Design 画布：<https://claude.ai/artifact/P9mddKiiDZTGZtrFjXPLpb>。`design/takt-handoff/prototype/` 是它的副本，2026-11-21 同步过（手机画板已含 Project 列表）。设计准则见 `design/guidelines.md`。
- **改 UI 先改画布**：在对应的画板（`Phone*.dc.html` 对应 iOS，`Main/Dark.dc.html` 对应网页，`Splash*`、`Icon*`）上做出效果，确认后再写进代码，并同步更新仓库里的副本。
