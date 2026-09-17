# 0.3.0 验证记录

环境：macOS 26.6 / Apple Silicon，Codex CLI 0.154.0-alpha.6.2，本机 Codex 已切换 `model_provider = "deepseek"`。

## 接入现状（实测）

- 该 Codex 目录下 `account/read` 返回 `{"account": null, "requiresOpenaiAuth": false}`，`account/rateLimits/read` 与 `account/usage/read` 都返回「codex account authentication required」。也就是说切换 DeepSeek 后，原有的额度与账号用量接口不再可用，必须新增 DeepSeek 数据源。未修改任何 Codex 配置。
- `GET https://api.deepseek.com/user/balance` 返回 `{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"16.07",...}]}`。多次请求之间余额持续变化（16.07 → 15.95 → 15.05 → 14.87 → 14.78），确认为服务端实时值。
- DeepSeek 没有公开用量接口：`/user/usage`、`/dashboard/billing/usage`、`/v1/dashboard/billing/subscription` 均为 404，`platform.deepseek.com` 相关路径返回 429。因此用量改用本机 Codex 日志口径，并在界面上明确标注。
- 用量事件口径核对：`token_usage_record.turn_token_usage` 是本轮累计值（会话内 15 条求和 4,944,284，是线程累计 769,187 的 6.4 倍），不可相加；`event_msg/token_count.info.last_token_usage` 才是每次请求的增量（15 条求和 769,187，与 `total_token_usage` 末值完全一致）。账本采用后者。
- 压缩会重置累计计数：一份 1.33 GB、跨 9 月 3—16 日的日志有 11 次累计重置，`threads.tokens_used`（241,672,600）只反映最后一次压缩之后的部分，而逐次增量求和为 1,200,782,546。因此账本不使用 `tokens_used`。

## 账本正确性

- 独立脚本全量读取 8 份 DeepSeek 日志，按「轮次模型 + 增量」求和得到 129,721,476；同一时刻 `CodexPulse --usage-check` 的账本读数同为 129,721,476，**差异为 0**。
- 同一目录下存在跨提供商的会话（同一份日志里既有 `deepseek-flash` 轮次也有 `gpt-6-astra` 轮次）。按会话行归属会把 8,918,593 Token 误算进 DeepSeek；改为按每轮 `turn_context.model` 归属后，DeepSeek 侧只剩 `deepseek-flash`。
- 尾部截断的边界已修正：原先跳过的整行会丢掉一整次请求的用量，现在先探测尾部起始字节是否为换行，仅在真正截断半行时丢弃。截断文件另加保护——在读到第一个 `turn_context` 之前不计数，避免把上一轮的模型猜错。

## 自动化与界面

- `scripts/swift-tool.sh test`：30 项通过（新增 15 项：配置扫描与凭据优先级、DeepSeek 余额解码与端点拼接、余额历史、账户注册表迁移、账本按日/按模型归集、增量与半行追加、尾部截断、累计回退、窗口过滤、账户类型过滤、混合会话语义）。
- Release 构建与 ad-hoc 签名通过；`~/Applications/Codex Pulse.app` 已更新为 0.3.0 并启动，旧 0.2.1 实例先退出再替换。
- 真实数据快照（非演示）验证：状态栏 `1 · ¥14.78`，概览显示余额、赠送/充值、今日 128.27M Token 与日志截断提示，任务区显示 1 执行中 / 44 已完成。
- 已渲染检查：DeepSeek 概览与用量页、Codex 概览（额度卡保留 + 本机用量卡）、设置页账户列表，均为深色演示数据。
- 账户迁移后立即写回偏好，确保账户标识稳定；否则每次启动都会换 UUID，`balanceHistory` 无法累积。已在安装后确认 `accounts`、`selectedAccountID`、`balanceHistory.<UUID>` 均已落盘。
- 复查时修掉两处真实缺陷：编辑账户换了数据目录后，运行时仍指向旧目录（读取器未重建）；删除账户或早期构建留下的无主 `balanceHistory.*` 会永久堆积，现在启动时会自检清理。安装后确认只剩当前账户一条记录。

**未验证**：多账户切换只用演示的两个账户渲染验证，没有第二台真实 Codex 登录目录；真实账户之间的切换需要在你有第二个目录时实测。DeepSeek 之外的第三方 OpenAI 兼容端点未验证。

# 0.2.1 验证记录

- 旧版真实任务的目录已不存在，点击后没有错误提示。确认历史工作目录未随文件夹整理更新。
- 新版详情与右键入口统一使用“在 Finder 中打开”，显示实际目录；失效目录弹出说明和“选择新位置…”，可进入原生目录选择器。
- 本机已核实的旧 Basic 目录通过本机偏好映射到当前目录；重启应用后详情正确显示新路径。映射不写入仓库或 Codex 数据库。
- 新版明确指定 Finder，异步请求；已验证 10 秒超时提示，以及关闭提示后面板仍可操作。
- **系统打开未通过端到端验证**：这台机器上 Launch Services 打开请求没有及时返回；同步诊断样本停在 `_sandbox_extension_issue` / `__mac_syscall`。Finder 自身可正常创建窗口。最终实现保留异步调用和超时反馈，不阻塞面板，不将此情况记为打开成功。
- 目录选择器已验证展示；自动化的路径跳转未完成，未将通过选择器持久化目录记为端到端通过。本机映射由已核实路径写入应用偏好，重启读取已验证。
- Release 构建、安装包签名和既有 13 项核心测试通过；本次交互变更以原生 UI 验证为主。

# 0.2.0 验证记录

环境：macOS 26.6 / Apple Silicon，Codex CLI 0.154.0。

- `scripts/swift-tool.sh test`：13 项通过，包含日志解析、额度口径，以及新增任务搜索 / 筛选 / 排序。
- Release 构建与安装包签名校验通过。
- 原生弹窗内验证：切换页面、输入 `pipeline` 筛选到 1 条任务、展开 Token 详情、打开并取消文件选择器，面板均保持可操作。
- Esc 关闭通过；创建独立预览窗口导致原弹窗失去焦点后，捕获到 `popoverDidClose`，验证自动收起。
- 原生事件监听覆盖本应用外的鼠标点击、本应用内其他窗口点击，以及应用失焦；关闭弹窗后移除监听。文件选择期间不触发误关闭。
- 自动化工具向后台窗口执行的 AX 操作不等同于硬件鼠标点击，因此没有将后台 Finder / LinearMouse 点击记为全局鼠标事件验证通过。
- 已渲染检查概览的深浅色、任务列表和用量页面。仓库截图全部使用演示数据。

旧版问题：点击刘海区域会固定展开，固定状态不会因点击外部而解除。0.2.0 移除整个刘海窗口与固定模式，回到状态栏弹窗，并补齐明确的收起处理。
