# Codex Pulse

一个原生 macOS 菜单栏小工具，随时查看 Codex 任务、账号额度与 Token 使用情况。SwiftUI + AppKit，中文界面，支持系统浅色 / 深色外观，无第三方运行时依赖。

![Codex Pulse 演示界面](docs/preview-dark.png)

## 能看到什么

- **菜单栏**：活跃任务数 + 主额度窗口剩余百分比，例如 `2 · 72%`。额度过期、断连或读取失败时显示 `—`。
- **额度**：按服务端实际返回的窗口展示剩余比例、重置时间、多模型额度、积分余额、可用重置次数。
- **任务**：本机最近 60 个未归档会话的标题、项目、模型、活动、执行状态、本轮 / 会话累计 Token、最近输入上下文占比。
- **账号使用**：累计 Token、连续使用天数、最近 7 个有记录日期的 Token 柱状图。
- **设置**：跟随系统 / 浅色 / 深色主题、状态栏仅图标、登录时启动、自定义 Codex 数据目录与 CLI 路径。开机启动默认关闭。

## 0.2.1 目录打开修复

- 任务按钮统一为“在 Finder 中打开”，详情显示实际目录。
- 旧目录移动或删除后明确提示，可选择并记住新位置；右键任务可“更改项目目录…”。同一旧路径的任务共用映射，仅保存在本机，不修改 Codex 历史记录。
- 明确指定 Finder，异步打开；失败和 10 秒未返回结果均显示提示，避免一直无反馈。超时不代表系统请求已取消，它仍可能稍后完成。

## 0.2.0 交互与界面

- 点击面板外部、切换应用或按 Esc 自动收起；右上角也有收起按钮。没有固定展开模式。
- 四个页面：概览、任务、用量、设置。任务搜索支持名称、项目路径、模型和会话 ID；多个关键词同时匹配。
- 支持全部 / 执行中 / 待确认 / 已完成 / 已中断 / 未知筛选，按任务状态、最近更新或累计 Token 排序。
- 点击任务展开详情，查看本轮 Token、上下文占比；可在 Finder 中打开目录或复制会话 ID。
- 额度显示重置倒计时、同步新鲜度和更新中状态；⌘R 立即刷新。
- 登录项与账号配置沿用已有设置。旧刘海面板及其开关已移除。

## 运行

需要 macOS 14+、Swift 5.9+ 编译器（测试需要 Swift 6+）以及已登录的 Codex CLI。当前已在 Apple Silicon、Codex CLI 0.154.0 上验证。Codex 的 App Server 与本地日志格式会变化；遇到不兼容数据会显示不可用。

```bash
git clone git@github.com:Yuwangzhi/codex-pulse.git
cd codex-pulse
./scripts/build.sh --install
```

脚本构建 `dist/Codex Pulse.app`，复制到 `~/Applications/Codex Pulse.app` 并启动。应用仅在状态栏显示，不占 Dock。更新安装前请先退出旧版本。

仅构建：`./scripts/build.sh`。退出：面板右下角电源按钮。卸载：退出后移除该 App；如果启用了登录时启动，先在设置中关闭。

本地构建使用 ad-hoc 签名，未经过 Apple 公证。分发到另一台 Mac 建议在目标机器上从源码构建。

## 数据来源与口径

| 内容 | 来源 | 刷新 |
| --- | --- | --- |
| 账号额度 | `codex app-server` → `account/rateLimits/read` | 每 60 秒及额度通知后 |
| 账号 Token | `account/usage/read` | 每 5 分钟 |
| 会话列表 | `CODEX_HOME/state_*.sqlite`，只读连接 | 每 2 秒 |
| 任务活动 | 对应 rollout JSONL，增量读取完整行 | 每 2 秒 |

使用 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 中的账号查询接口。Pulse 启动独立的查询进程，复用 Codex 自己的登录流程；不调用模型任务接口，不自动消费额度重置次数。退出后关闭自己的查询进程。

**任务状态是本机日志观测，不是桌面应用的全局运行状态 API。** 最近 120 秒内的未结束活动显示“执行中”；超过 120 秒没有新事件显示“待确认”，工具可能仍在执行；只有 `task_complete` / `turn_aborted` 才显示完成 / 中断。某些审批等待没有可用日志事件，因此不猜测“等待审批”。云端和其他设备的任务不在本机任务列表内，账号统计则采用服务端返回的账号范围。

首次最多读取每个日志的末尾 4 MiB，此后只读取新增字节。历史上下文被截断时，无法恢复的字段保持未知。只读最近 60 个未归档会话；早于此范围的长任务可能不显示。会话 Token 使用累计值覆盖，避免把每次上报的累计数重复相加。本轮 Token 取 `turn_token_usage`，旧格式没有该字段则显示 `—`。上下文占比取最近请求的输入 Token / 上下文窗口，是近似指标。

额度窗口使用服务端实际时长，**不假设一定有“5 小时 + 每周”两种额度**。过了重置时间不会自行恢复为 100%，需要下一次服务端快照。积分是服务端的 credits 单位，不代表美元或剩余 Token。未返回的余额、百分比和计数均显示未知；不把缺失值当成 0。账号每日统计保留服务端日期，不承诺自然日时区，也不将最后一个日期冒充“今日”。

## 隐私

Pulse 本身不读取、复制或保存 `auth.json`、API Key、账号邮件；不保存会话正文，也不上传本机任务信息。CLI 自行处理登录与额度网络查询。日志解析会在内存中解码事件，仅投影任务状态、工具名和用量；原始记录不落盘。会话标题只在本机 UI 展示。仓库不包含真实会话、账号快照或凭据，截图使用明确标记的虚构演示数据。

设置保存在 macOS UserDefaults。不写入 Codex 配置或会话库；Codex 查询进程自身仍可能按其正常行为维护运行时元数据。

## 开发与验证

```bash
./scripts/swift-tool.sh build
./scripts/swift-tool.sh test
./scripts/build.sh
"dist/Codex Pulse.app/Contents/MacOS/CodexPulse" --diagnose
"dist/Codex Pulse.app/Contents/MacOS/CodexPulse" --demo --show --ui-check
"dist/Codex Pulse.app/Contents/MacOS/CodexPulse" --demo --dark --screenshot /tmp/pulse-dark.png
```

`--diagnose` 运行 20 秒后退出，仅输出连接成功与否、记录数量等摘要，不输出标题、账号 ID、积分或日志正文。演示模式不连接 CLI 或读取本机会话。`scripts/swift-tool.sh` 为部分 Command Line Tools 版本补全其自带 SwiftPM 框架搜索路径，所有设置仅影响当前构建进程。

`--show` 打开实际状态栏弹窗；`--ui-check` 只在标准输出记录弹窗显示 / 关闭，供原生交互验证。`--tab 0/1/2/3` 可选择截图页面。

测试覆盖：任务跨字段搜索、状态筛选、不同排序与稳定顺序；任务生命周期、长时间无事件、跨轮次结束事件、累计 Token 去重、缺失额度、不同时长窗口、过期重置时间、分段写入、日志截断 / 替换及有界尾部读取。

## 目录

```text
Sources/CodexPulse/       菜单栏、SwiftUI 面板、账号 RPC、刷新调度
Sources/CodexPulseCore/   数据模型、只读数据库、增量日志解析
Tests/                   合成数据测试，不依赖真实 Codex 账号
Resources/               App 元数据
scripts/                 构建、安装、图标生成
```
