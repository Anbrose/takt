# TAKT iOS

SwiftUI，iOS 17+，Swift 6。

```
Takt.xcodeproj       App 外壳（只有 TaktApp.swift + 资源），依赖本地包 TaktKit
Takt/                App 源文件（文件夹同步组，新文件放进来就会自动加入工程）
TaktAppUITests/      XCUITest：进入下一级 / 返回、拖动 + 取消、拖动 + 保存、勾选 + 新建
TaktKit/             Swift Package
  TaktCore           端上需要即时反馈的规则（直线距离、距离显示格式、落点计算）
  TaktAPI            由 openapi.json 生成的客户端 + LiveBackend 封装
  TaktUI             主题、规划模式界面、LevelModel / PlanModel、InMemoryBackend
```

## 运行

1. 启动后端：在仓库根目录运行 `pnpm seed && pnpm dev`。
2. 打开 `Takt.xcodeproj`。第一次构建时 Xcode 会请求信任 `OpenAPIGenerator` 插件，点「Trust & Enable」。
3. 选 Takt scheme，在模拟器上运行。默认连接 `http://127.0.0.1:3000`；可以在 scheme 的环境变量里改 `TAKT_API_URL`（真机要填 Mac 的局域网 IP）。
4. 不想启动服务器的话，在 scheme 里勾选启动参数 `-demo`，App 会改用内存里的日本旅行示例数据。

## 测试

```sh
cd TaktKit && swift test        # 状态逻辑、规则（对照 fixtures/cases.json）、API 解码，在 Mac 上跑，几秒钟
xcodebuild test -project Takt.xcodeproj -scheme Takt \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -skipPackagePluginValidation
# 让 UI 测试连真实后端（会修改那台服务器上的数据）：
#   在上面的命令前加 TEST_RUNNER_TAKT_UITEST_SERVER=http://127.0.0.1:3000
```

## API 客户端

`TaktKit/Sources/TaktAPI/openapi.json` 由仓库根目录的 `pnpm openapi` 写入（和 `packages/contract/openapi.json` 是同一份）。`pnpm test` 会检查这两份是否最新。改了接口之后重新生成，再构建 iOS 即可。
