# talk2ppt · 映稿

映稿 0.5.1 是一款原生 SwiftUI Mac 图片型演示文稿工作台：填写固定和可变提示词，通过 **Sign in with ChatGPT** 调用原生 image-gen，选择图片入库，排序后导出 PPTX 或 PDF。

本仓库仅包含应用源代码、构建脚本和合成测试数据的生成代码，不包含账号、凭据、私人提示词、项目数据、生成图片或预编译运行时。

## 功能

- 按项目保存提示词、候选图片和已入库图库。固定提示词可收起，收起后仍参与生成。可变提示词支持一键清空和撤销清空。
- 每次生成一张，或顺序生成三张候选、选择其中一张“确认入库”。其余候选保留在项目垃圾箱。
- 开始生成时清空旧预览，显示当前张数、已用时间和明确标注的预估进度。实际完成以原图返回为准。
- 复制待入库图片后，可选择“仅复制”或“确认入库”；已入库图片不会重复询问。
- 连接区域和工具栏显示当前调用模型，可查看运行时返回的模型列表、刷新及切换，选择保存在本机。生成期间禁止切换；生图工具仍为原生 image-gen。
- 点击预览图片即可放大，支持复制到 Mac 剪贴板。提示词面板和图库均可收起，预览随可用空间等比扩大。图库支持拖动缩略图到目标左／右侧插入，或拖到末尾；也支持右键前移／后移。
- 按图库顺序导出图片型 PowerPoint（`.pptx`）或 PDF（`.pdf`），每张图片一页。16:9 页面等比居中，比例不符时留白，不拉伸、不裁切。
- 图片删除需要二次确认，移入项目垃圾箱后可恢复。项目删除后进入“已删除项目”，内容完整保留，可恢复。

PPTX 中每页包含一张图片；图片内的文字不是独立可编辑文本。导出模块在本地运行，不依赖 PowerPoint、其他办公软件或外部服务。

## 要求与登录

- macOS 14 或以上，Apple Silicon（arm64）。
- 构建需要 Xcode Command Line Tools，可通过 `xcode-select --install` 安装。
- 生图需要联网、可用的 ChatGPT 登录及相应账号能力和配额。
- 当前锁定 **Codex CLI 0.163.0**，通过官方本地 App Server 通信。需要同一发行包中的 `codex` 和 `codex-code-mode-host` 两个原生可执行文件。

应用只接受 ChatGPT 登录，不使用 API 密钥，也不自动切换其他生图服务。凭据由官方 Codex 运行时管理，不写入项目。官方资料：[认证说明](https://developers.openai.com/codex/auth/)、[App Server](https://developers.openai.com/codex/app-server/)。不同账号或后续运行时版本的 image-gen 可用性需要实际验证。

## 构建与运行

安装匹配版本的官方运行时后执行：

```sh
npm install -g @openai/codex@0.163.0
./scripts/build.sh
open dist/映稿.app
```

构建脚本先使用 `PPT_WORKFLOW_CODEX_PATH`，否则检查 `PATH` 中的原生运行时和全局 npm 包。也可明确指定原生可执行文件：

```sh
PPT_WORKFLOW_CODEX_PATH=/path/to/native/bin/codex ./scripts/build.sh
```

该路径必须指向原生 `codex`，不是 npm 的 JavaScript 启动器；同目录必须有 `codex-code-mode-host`。脚本检查版本，将这两个文件打包进 `.app`，完成 ad-hoc 签名和校验后再原子替换 `dist/映稿.app`。旧版本保留在 `.build/previous-app/`，不会覆盖仍在运行进程所映射的文件；更新后退出并重新打开应用生效。

产物供本机使用，未进行 Developer ID 公证或 App Store 分发。仓库不提交第三方运行时二进制。

## 使用流程

1. 新建项目；等待“ChatGPT 已连接”，或点击“Sign in with ChatGPT”在浏览器完成授权。
2. 填写固定提示词和可变提示词。两者按固定在前、可变在后的顺序合并，输入自动保存。
3. 选择“1 张”或“3 张选 1”，点击生成。三张模式会顺序发起三次独立原生生图请求，使用本次点击时捕获的同一份提示词。
4. 在候选中选择满意的一张，点击“确认入库”。可放大检查，或复制到其他应用。
5. 在图库调整顺序，点击“合并导出”，选择 PPTX 或 PDF，再选择保存位置。只有已入库图片参与导出。
6. 图片误删可从项目垃圾箱恢复；项目误删可从侧边栏“已删除项目”恢复。垃圾箱不会自动清空。

已经返回的候选会逐张自动保存。批次中途失败或停止时，已完成的结果保留；应用重开可加载已保存候选，但不会自动续跑未完成任务或自动重复生图。新批次第一张图片保存成功后，上一批未入库候选会移入垃圾箱。生成期间修改输入不会改变已经提交的提示词快照。

图库、排序、垃圾箱和导出可以离线使用。当前不包含讲稿自动分页、AI 改写提示词、参考图上传、跨页面批量队列或模板管理。

## 本地数据与备份

应用数据与源代码分离，默认存放在：

```text
~/Library/Application Support/YingGao/Projects/<project-uuid>/
  project.json          项目、提示词、候选、图库顺序与删除状态
  project.backup.json   上一次保存的记录备份
  assets/               原始图片
```

元数据原子写入并保留备份。图片移入垃圾箱和项目删除只修改记录，原图仍保留在项目内。可通过工具栏“在 Finder 中查看”打开项目目录；备份时复制完整 `Projects` 文件夹。移除 `.app` 不会删除项目数据。

不要将此数据目录、Codex 配置／凭据目录、生成日志或截图加入公开仓库。`.gitignore` 使用允许列表，默认排除验证产物、私人文档、旧原型、`.build/`、`dist/` 和凭据文件。

## 测试

离线检查使用临时目录和程序生成的合成图片，不需要个人图片、账号或真实生图：

```sh
./scripts/test.sh
```

覆盖存储迁移、候选择一入库、排序、删除恢复、失败写入保护、批次取消和模拟协议，以及导出页序、比例、图片和文件结构。模拟服务测试需要 `/usr/bin/python3`，随当前 Xcode Command Line Tools 提供。

可另外构建隔离的离线界面测试应用，使用新临时目录中的合成图片，不访问日常项目：

```sh
./scripts/test-ui-build.sh
open .build/映稿界面测试.app
```

该脚本仅对测试构建启用 `UI_TESTING`；生产构建不启用测试数据入口。

`ServicePreflight.swift` 和 `LiveSimpleSmoke.swift` 不包含在默认离线测试中。前者手动检查真实运行时和当前登录状态；后者必须单独选择启用，会使用当前登录账号的生图配额：

```sh
xcrun swiftc -parse-as-library \
  Sources/SimpleApp/CodexImageService.swift \
  Sources/SimpleApp/ProjectStore.swift \
  tests/LiveSimpleSmoke.swift -o .build/LiveSimpleSmoke
PPT_WORKFLOW_CODEX_PATH="$PWD/dist/映稿.app/Contents/Resources/codex" \
  .build/LiveSimpleSmoke --live
```

不传 `--live` 不会发起真实生成。实时检查的输出保存在忽略的 `validation/` 目录中。自动检查不能替代真实窗口、实际登录及办公软件打开导出文件的验收。

## 代码结构

- `Sources/SimpleApp/SimpleApp.swift`：主窗口、提示词和候选预览。
- `CodexImageService.swift`：官方运行时通信、登录、原生生图与取消。
- `GenerationCoordinator.swift`、`GenerationProgressView.swift`：顺序批次、输入快照和预估进度。
- `ProjectStore.swift`：本地持久化、排序、图片和项目垃圾箱。
- `ProjectGalleryView.swift`、`ProjectTrashView.swift`、`DeletedProjectsView.swift`：图库及恢复界面。
- `ProjectExportView.swift`、`ImageDeckExporter.swift`：保存对话框与原生导出。
- `tests/`：合成图片、离线存储／协议／生成／导出检查及显式启用的实时检查。
