# 技术决定

开工前定下的事（对应 `design/takt-handoff/HANDOFF.md`「开工前需要先定的事」），2026-11-13 确认。

| #   | 事项       | 决定                                                                                             |
| --- | ---------- | ------------------------------------------------------------------------------------------------ |
| 1   | 后端       | Node.js（≥22）+ Fastify 5。请求/响应用 Zod 4 定义在 `packages/contract`，`openapi.json` 由它生成 |
| 2   | iOS        | SwiftUI 为主，目标 iOS 17+；拖动排序先做技术验证，不够流畅就那一块改用 UIKit `UICollectionView`  |
| 3   | 账号       | 先做单用户。`projects.owner_id` 已经预留，每个查询都按 owner 过滤；目前固定为 `local`            |
| 4   | 数据库     | PostgreSQL + Drizzle ORM。没有 `DATABASE_URL` 时用内嵌的 PGlite（开发和测试都用它）              |
| 5   | 地图       | iOS 用 MapKit；网页用 Google Maps JS 还是 Mapbox，到做网页时再定。「最短」默认按**耗时**         |
| 6   | 路线计算   | 后端统一计算并缓存。端上只用直线距离估算，给拖动时的「预览中」即时反馈                           |
| 7   | AI 辅助    | 第一阶段不做。以后做成按钮形式（从模板生成 / 补全前置条件），不做对话框                          |
| 8   | 进行中进度 | 存在后端，按任务记 `completed_at`，不按下标记。当前项 = 按规划顺序第一个未完成的叶子任务         |
| 9   | 勾选范围   | 只在端上，不落库。调用 `GET /tasks/{id}/plan?scope=` 时作为参数传给后端                          |
| 10  | 紧急程度   | API 从一开始就支持；新建时界面默认「行前订」（`before`）                                         |
| 11  | 示例数据   | 日本旅行，见 `packages/fixtures/data/japan-trip.json`，用 `pnpm seed` 导入                       |

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
