# DogSC：自选摄像头 LUT 与 MCP

本分支在上游 DogSC 的原生 macOS 应用中加入可移植摄像头 LUT 和 21 个 MCP 工具。原摄像头轨道保持未调色；实时预览、剪辑预览和 MP4 成片使用同一 Core Image LUT 实现。

## 构建和启动

沿用 `Package.resolved` 的 Sparkle 2.9.4，Swift 6，Apple Silicon 与 Xcode 26+。

```sh
security find-identity -v -p codesigning
DOGSC_SIGNING_IDENTITY="你的证书 SHA-1" bash build-app.sh
# 开发迭代可加 DOGSC_BUILD_CONFIGURATION=debug
open ".build/local/DogSC Dev.app" --args --automation
```

可用 `DOGSC_APP_OUTPUT="/新的路径/DogSC Dev.app"` 把构建产物放到另一个目录，避免替换正在录制的应用。

开发版 bundle ID 为 `cn.laogou.dogsc.dev`，与正式版并存，场景预设和背景资源也分别保存。第一次使用需要自行完成 macOS 的摄像头、麦克风、屏幕录制和辅助功能授权。MCP 不会绕过权限。

`--automation` 开启并记住本开发版的本机接口设置，重启后仍可用。关闭方式：退出开发版，再以 `--no-automation` 启动。没有显式开启过的安装默认关闭接口。

## LUT 使用

- 录制前：摄像头弹窗 → **摄像头 LUT → 导入 .cube…**。可调 0–100% 强度、开关、移除。
- 剪辑时：摄像头检查器中的同名面板。更换 LUT、强度和开关进入正常撤销历史。
- 支持标准 RGB 顺序的 3D `.cube`，2–65 阶，最大 32 MB，默认或显式 `DOMAIN_MIN 0 0 0` / `DOMAIN_MAX 1 1 1`。
- 不支持 1D、混合 1D+3D、非 0–1 domain 或 `LUT_*_INPUT_RANGE` 扩展；会明确报错，不会静默生成错误颜色。
- LUT 按 sRGB 编码值查表。Log 摄像头请使用与实际输入匹配的 LUT；软件不会猜测或自动加入 Log/色域变换。上游输出仍为 SDR。
- LUT 表嵌入项目。移动原 LUT 后仍能预览和导出；录制前设置只作用于当前准备的 take，录制后可在编辑器重新修改。
- 项目格式升至 28，旧版本项目仍可打开。上游只支持到 27 的应用会拒绝打开新保存的项目，避免悄悄丢失 LUT。

## Codex 接入

MCP stdio bridge 使用 Python 3.9+ 标准库，不需要 pip、Node、API key 或云服务。配置示例见 `mcp/config.toml.example`，将路径改为本机绝对路径。可以放在受信任项目的 `.codex/config.toml`，也可以注册到用户的 Codex 配置：

```sh
codex mcp add dogsc -- /usr/bin/python3 "/ABSOLUTE/PATH/dogsc/mcp/server.py" \
  --app "/ABSOLUTE/PATH/dogsc/.build/local/DogSC Dev.app"
codex mcp get dogsc
```

`--app` 会在连接不可用时尝试启动开发版。若应用已经在未开启 automation 的状态运行，请先退出再启动。Codex 的当前聊天不会因此自动获得新工具；重新加载 MCP 或在同一项目新开聊天后使用。

配置方式依据 [OpenAI 的 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。协议使用 [MCP stdio](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) 和 [tools/list、tools/call](https://modelcontextprotocol.io/specification/2025-03-26/server/tools)。

## 工具覆盖

| 功能 | 工具 / 参数 |
|---|---|
| 状态、权限、错误、导出进度、最近项目 | `dogsc_status` |
| 摄像头、麦克风、显示器、iOS 设备枚举 | `dogsc_sources` |
| 可录窗口枚举 | `dogsc_windows`（需屏幕录制权限） |
| 录制来源、区域、编码、分辨率、系统声音、麦克风、摄像头 | `dogsc_capture_configure` |
| 开始、停止、暂停、继续、标记、保存、转剪辑 | `dogsc_recording` |
| 打开、完整参数读取、保存 | `dogsc_project_open/get/save` |
| 画布比例、裁切、背景、边框、样机、阴影 | `dogsc_project_patch.canvas` |
| 摄像头布局、形状、镜像、大小、隐藏 | `dogsc_project_patch.camera` |
| 自定义 LUT 导入、强度、启停 | `dogsc_lut` |
| 光标样式、点击反馈、运动参数、开场 | `dogsc_project_patch.cursorStyle/motion/openingSequence` |
| 摄像头音画同步、起点、漂移与锚点 | `dogsc_project_patch.media.camera` 时间字段（素材路径只读） |
| 音量与静音 | `dogsc_project_patch.audio`、`timeline.primarySegmentAudioOverrides` |
| 分割、裁剪、重排、变速、移除片段 | `dogsc_timeline` |
| 自动/手动缩放、3D、摄像头动画、柔化、突出、贴图、轨道顺序、恢复剪辑 | `dogsc_project_patch.timeline` 完整参数 |
| 播放、暂停、定位 | `dogsc_playback` |
| 撤销、重做 | `dogsc_history` |
| 场景预设列表、保存、应用 | `dogsc_presets` |
| 拷贝背景图片/视频、贴图到项目 | `dogsc_asset_import` |
| 更换摄像头视频 | `dogsc_camera_replace` |
| MP4 / M4A、全片或范围导出、取消 | `dogsc_export` / `dogsc_export_cancel` |
| 帧率、原始分辨率/1080p/1440p/4K | `dogsc_project_patch.exportSettings` |
| 导出未调色原始素材 | `dogsc_sources_export`（异步，轮询 `status.sourceExport`） |
| 主题、语言、导出目录/声音、悬停预览设置 | `dogsc_settings` |
| 设置窗口、备忘录、快捷键、来源选择、隐私设置、关闭项目 | `dogsc_ui` |

这是核心录制/剪辑/调色/导出功能的程序化接口，并非每个 UI 控件的等价 RPC。系统权限、软件更新、预设删除/默认项、部分界面偏好仍使用 `dogsc_ui` 打开的现有界面；不会把“打开了对话框”报成“操作已完成”。无任意脚本执行或项目删除接口。

## 调用示例

先调用 `dogsc_status`。开始操作前检查正确的 phase；打开项目后等待 `editorReady=true` 和 `projectPath` 一致。

录制前导入（原相机画面保留）：

```json
{"name":"dogsc_lut","arguments":{"action":"import","target":"recording","path":"/Users/you/LUTs/My Look.cube"}}
```

剪辑中调整强度：

```json
{"name":"dogsc_lut","arguments":{"action":"configure","target":"editor","intensity":0.65,"enabled":true}}
```

完整项目接口返回 `{revision, project}`。对象递归合并，数组整体替换，`null` 移除可选字段。修改时使用刚读到的 revision；过期会拒绝，防止覆盖手动操作。

```json
{"name":"dogsc_project_patch","arguments":{"expectedRevision":"上次读取的 revision","patch":{"camera":{"size":0.35,"position":{"x":0.8,"y":0.75}},"exportSettings":{"frameRate":30,"resolution":"1080p"}}}}
```

不要猜 enum 原始值：先读取项目/配置。上游 `CaptureSource` 的值为 `整块屏幕`、`单个窗口`、`自选区域`、`iOS 设备`；`dogsc_ui.selectSource` 额外接受 `display/window/area/device`。录制编码目标仍沿用上游固定 60 FPS，导出支持 30/60 FPS。

时间线工具 `list` 返回片段 ID 和输出时间。`split` 需要 `time`；`trim` 需要 `segmentID/edge/time`；`move` 需要 `segmentID/index`；`speed` 需要 `segmentID/rate`。修改均传 `expectedRevision`。高级效果通过项目完整时间线参数读写，使用与 UI 相同的校验边界。

```json
{"name":"dogsc_export","arguments":{"path":"/Users/you/Movies/graded.mp4","kind":"video"}}
```

导出返回 `accepted` 后轮询 `dogsc_status.export`。只有 `running=false`、`error` 为空、`path` 为请求路径才能视为完成；已存在的输出路径会拒绝覆盖。

## 本机接口边界

应用只监听 `127.0.0.1` 的临时端口，每次进程启动生成新令牌。发现文件位于 `~/Library/Application Support/DogSC-Automation/endpoint.json`（目录 0700、文件 0600）。不要复制或提交这个文件。stdio 进程读取令牌后通过本机 JSON socket 调用应用；stdout 只写 MCP JSON。请求最大 16 MB，连接有超时与数量限制。

## 验证

```sh
swift test
python3 -m unittest discover -s mcp -v
# 需要运行中的空闲开发版与 ffmpeg；只生成测试媒体，不开启摄像头或录屏
python3 mcp/smoke_test.py
```

端到端测试会创建 `.build/mcp-smoke-*/`，验证真实 stdio 握手/工具发现、项目打开、LUT 导入、版本冲突、非法参数、撤销重做、分割、项目保存、移动原 LUT 后导出、已有文件拒绝覆盖，以及成片像素确实由蓝色变红、旁路仍是蓝色、原素材 SHA-256 不变。测试生成的项目会留在编辑器供检查。
