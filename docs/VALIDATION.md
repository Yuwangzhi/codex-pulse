# 0.5.6 菜单栏独立启动与恢复（2026-10-23）

- 系统设置现场确认 AI Pulse 开启、Grok Bot / Tailscale 关闭；按用户要求关闭 CC Switch 的菜单栏显示。系统历史归属记录同时在终端 / ChatGPT 下列出 AI Pulse，在 Grok Bot 下列出 Tailscale；未直接改写这些系统记录，也未将历史记录当作单独的因果证明。
- 状态项设置固定 `autosaveName=AIPulseQuota`；显式重新打开时重新登记可见状态，并展示独立窗口。系统关闭自己的菜单项后，原生 UI 验证重新打开仍能查看监控，窗口内收起按钮正常工作。不能仅凭 `NSStatusItem.isVisible` 判断系统托管项是否实际显示。
- 安装等待旧进程完全退出，再替换已备份的应用。通过短暂的 GUI launchd 任务调用 Launch Services，成功 / 失败均清理任务；真实启动退出码为 0，未留下该启动任务或新增登录启动设置。
- 最终安装版本中，将 CC Switch / Grok Bot / Tailscale 全部开启，再依次关闭 Grok Bot、Tailscale、CC Switch：系统 UI 中 AI Pulse 始终开启，本应用状态项标识、可见标志及屏幕内锚点持续正常。最终为 AI Pulse 开启、其余三个关闭。此项结合系统设置、AppKit 锚点及原生窗口验证；未把锚点诊断冒充系统托管菜单栏的像素截图。
- 原生已安装窗口确认 GPT、Grok 服务端额度、Claude 官方 5 小时 / 每周额度和本机任务可用；启动时钥匙串读取曾较慢，随后 Grok / Claude 均恢复服务端来源和新的读取时间，无需改变权限。
- `./scripts/swift-tool.sh test`：63 项通过；Release 构建与安装、`bash -n`、`git diff --check`、严格签名校验通过。最终安装 / 构建二进制 SHA-256 一致；账户、选中账户、主题、compactStatus、floatingEnabled、projectDirectories 六项原偏好哈希不变。版本 0.5.6，原 bundle identifier 保持不变。

# 0.5.5 Claude 官方用量与两列状态栏（2026-10-22）

- 修改前备份源码、工作区 diff 和偏好；保留原 GPT / Grok 服务端查询、任务监测、可选悬浮窗与账户设置。
- 状态栏原生控件验证两列：左列 GPT / Grok 剩余，右列官方 Claude 5 小时 / 每周剩余百分比（由已用换算），无图标或 Claude 名称。合成有登录、无登录截图已检查；无官方登录时右列无占位符，缺失窗口不补零。
- `./scripts/swift-tool.sh test`：63 项通过。新增覆盖官方 utilization 换算为剩余（24%→76%、超额→0%）、服务明确返回 0、部分 / 缺失 / 非法窗口、重置后不展示旧窗口、官方路由判定、中转 / API Key / 云后端隔离、作用域与到期校验、Token 切换、固定官方 HTTPS 请求、自定义配置不借用全局登录、凭据只读。
- 官方 OAuth 用量接口实际返回 200；已安装 0.5.5 的诊断与原生概览均读到 5 小时已用 2%、每周已用 0%（换算后显示剩余 98% / 100%），无查询错误。概览标注官方来源、剩余口径、各窗口重置时间和读取时间。
- 已安装 App 的实际状态栏原生截图确认 `GPT 80% / Grok 50%` 与右列 `2% / 0%` 对齐且未裁切；无手动刷新时，Claude 读取年龄从 54 秒回到 5 秒，确认定时查询实际运行。
- Release 构建、安装、严格签名验证通过；安装 / 构建二进制 SHA-256 一致。安装前后账户、选中账户、主题、compactStatus、floatingEnabled、projectDirectories 均保持一致。
- 只向 Anthropic 官方用量接口发送 Access Token，禁止重定向；没有调用模型、使用 Refresh Token、改写 Claude 登录或记录凭据。每 60 秒查询；官方登录、路由或凭据变化时丢弃旧结果，HTTP 限流退避；同凭据临时失败保留原时间并标明上次记录。

# 0.5.4 上下两行状态栏（2026-10-21）

- 状态栏改为 GPT 上行、Grok 下行，保留百分号、未知值和无图标样式。使用原生双行文字，按最长一行确定宽度；菜单栏控件原生截图已确认两行完整、上下均留有空隙。
- Release 构建通过，文档中的合成状态栏截图已更新。每 60 秒服务端查询、手动刷新和悬停来源提示保留。
- 已安装 0.5.4，严格签名校验通过，安装与 Release 二进制 SHA-256 一致；原账户、主题、目录映射和显示偏好逐项哈希一致。
- 已安装 App 的实际状态栏截图确认：上行 `GPT 93%`，下行 `Grok 62%`，无图标、无裁切。

# 0.5.3 Grok 服务端额度查询（2026-10-21）

- 对照本机 Grok Bot 0.72.0 的周额度实现和协议，使用同一 `aiserver.v1.DashboardService/GetSandUsageStatus` 接口。与 GPT 一样每 60 秒主动查询，手动刷新可立即重查；本机状态仍每 2 秒更新。
- `./scripts/swift-tool.sh test`：57 项通过。新增覆盖当前账户与 JWT subject 的绑定、切换账户及退出登录、限定作用域的密文、团队切换、Electron v10 解密合成样本、固定 HTTPS 地址与认证头、额度/时间解析、缺失/企业池额度、超额归零及失败/过期标记。
- 原生已安装界面验证：钥匙串授权由用户本人处理，之后 Grok 显示「服务端额度 · 每 60 秒查询」，剩余约 62.7%，取代旧缓存的约 66.8%。点击刷新后查询时间更新，来源保持服务端。
- 不再手动操作的情况下观察完整轮询周期：读数年龄从 55 秒自动回到 12 秒，服务端来源保持不变，确认定时请求实际运行。
- 最终 0.5.3 Release 构建、安装和严格签名校验通过，安装二进制与构建 SHA-256 一致；最终安装包重新启动后，原生界面再次确认服务端额度可用。
- 只读取当前账户的 Access Token，检查当前账户与团队选择，禁止携带凭据跟随重定向。未调用模型，不读取或轮换 Refresh Token，不改写 Grok Bot 登录或缓存文件，不记录凭据或原始响应。自动轮询不请求交互式授权；授权入口由用户显式触发。
- 未授权、登录过期、接口缺失或网络失败时，保留可用旧读数并标明来源、时间与错误；账户/团队切换时清除旧结果。原账户与界面偏好逐项哈希未变化。

# 0.5.2 精简状态栏验证记录（2026-10-21）

- 修改前备份源码、工作区 diff 和原偏好哈希，保留此前未提交的监控功能。
- 状态栏使用 `GPT 数字%；Grok 数字%`，无图标、缓存星号或 Claude。数字沿用剩余百分比；未知仍为 `—`，旧缓存提示保留在悬停及详情中。
- `./scripts/swift-tool.sh test`：51 项全部通过；Release 构建、安装及 `codesign --verify --deep --strict` 通过。已安装 0.5.2 与 Release 二进制 SHA-256 一致，原账户、主题、目录映射和显示偏好哈希保持一致。
- 已安装 App 的原生状态栏控件截图确认实际读数 `GPT 95%；Grok 66%`，无图标或 Claude；合成读数 `GPT 58%；Grok 86%` 的文档图片同步更新。名称与百分号调整后重新通过 Release 构建、安装、严格签名与二进制一致性校验。

# 0.5.1 三家额度状态栏验证记录（2026-10-19）

- 修改前再次备份整个源码 / 文档及工作区 diff，保留 0.5.0 安装备份。版本升至 0.5.1，bundle identifier 保持不变。
- `./scripts/swift-tool.sh test`：51 项全部通过；新增最紧 GPT 窗口选择、离线快照标记、Claude Key 不限额不等于账户余额、不拿累计消耗当余额、Key 限额与未知货币单位、Grok 旧缓存及退出登录后的隔离检查。
- Release 构建、安装、严格签名校验通过，构建与安装二进制 SHA-256 一致。原 accounts、selectedAccountID、theme、projectDirectories、compactStatus 的逐项哈希未变化；新布局迁移只默认关闭悬浮窗，旧的仅图标值保留但不再隐藏额度文字。
- 原生 `NSStatusItem` 实际控件渲染验证三家文字完整显示；合成菜单栏图 `quota-status-demo.png` 与展开页 `quota-menu-dark.png` 均已检查，重置时间单独换行。原生已安装展开页验证 GPT 当前额度、Grok 的旧缓存星号 / 读取时间、Claude 未知余额和来源提示。
- 状态栏入口固定显示 GPT、Grok、Claude；点击后打开概览。原任务动态、CC 中转详细页、可选悬浮状态灯保留。GPT 状态栏来源独立于详情选中的 DeepSeek 等账户，为一个 Codex 账户保留额度连接；其他后台 Codex 账户仍保持停止。
- Claude 只采用 CC Switch 当前提供商。当前 4Router 未获得有效账户余额时显示 `—`，不取 ZZS 等其他来源补位，不将 Key 不单独限额显示成无限余额。Grok 读取桌面客户端当前账户的缓存，超过五分钟加 `*`；详情写明读取时间。

# 0.5.0 悬浮状态灯与 Grok 验证记录（2026-10-19）

- 在已有未提交的 0.4.0 改动上扩展，修改前将源码、资源、文档和工作区 diff 备份至本机 AI Pulse backups 目录。
- `./scripts/swift-tool.sh test`：47 项全部通过。新增覆盖 Grok 双命名字段、旧轮次报告、子任务隔离、继承的 Claude hooks 去重、权限与空闲通知、静默 / 进程退出、按来源和会话隔离、事件时间倒序、隐私字段白名单、配置合并 / 移除 / 备份 / 幂等、格式错误不覆盖，以及 Grok Bot 当前账户缓存隔离和过期标识。
- Release 构建与安装成功，`codesign --verify --deep --strict` 通过；构建与安装二进制 SHA-256 相同。版本 0.5.0，bundle identifier 保持不变。
- 安装后的实际 hook 命令端到端验证：两个来源的会话独立变化；等待输入、执行、旧轮次 Stop、取消、回复结束均符合预期。Grok 继承的 Claude handler 不产生重复记录；hook 无 stdout/stderr，无审批决定；示例对话字段没有出现在状态文件。单次本地采集耗时约 98–100 ms。验证后移除本次生成的独立测试会话文件。
- 安装前后 accounts、selectedAccountID、theme、compactStatus、projectDirectories 逐字段哈希一致；从更新后的 Claude 配置剥离本应用 handlers 后，与修改前的其他设置语义哈希一致。每次配置变更有权限受限的备份。
- 原生 UI 已验证：浮窗显示真实 Codex 活动及 Grok Bot 桌面在线条目；点击进入任务页；设置中 CC / Grok CLI 均为已启用；隐藏浮窗后可重新显示。实际浅色界面与合成深色浮窗均已检查，浅色状态文字使用深色琥珀 / 绿色提高对比度。
- Grok Bot 0.71.2 实机缓存核验：presence 和 account-slot 为 schema 1，weekly-usage.cache 为 schema 2。已安装界面显示与当前账户缓存一致的额度剩余、重置时间、读取时间及「上次记录」，不会取其他账户的缓存。只读这三个文件类型，不读取 secrets、转录内容、草稿或浏览器存储。
- 文档图片 `floating-dark.png` 仅使用合成数据。没有新增监听端口，也没有为了验证而调用模型。

限制：CC / Grok CLI 的真实模型回合没有额外发起；配置已启用，新开会话生效。Grok Bot 桌面客户端只提供本地存在 / 登录标记和额度缓存，没有持久化明确的任务运行状态，因此桌面条目显示灰灯待确认，不能据此判断各个 Bot 是否完成。额度来自客户端缓存，超过五分钟标注旧记录。`Stop` 是回复结束 hook 的观测，其他阻塞式 Stop hooks 可能继续当前任务，后续活动会重新变黄。

# 0.4.0 AI Pulse 验证记录（2026-10-18）

- `./scripts/swift-tool.sh test`：37 项全部通过；新增 6 项覆盖代理数据源隔离、Claude Desktop / Codex 排除、时间窗口、只读数据库不变、SQL 参数绑定、缓存 Token 口径、请求时长加权、缺失与过短计时、无限额 Key 与账户余额的区分、额度缺失值和到期时间。
- 原账本测试使用 2026-09 固定日志但依赖机器当前日期，现已超出 30 天窗口；修正为显式传入固定测试时间，不改变生产过滤规则。
- Release 构建、ad-hoc 签名、安装后 `codesign --verify --deep --strict` 通过，构建与安装二进制 SHA-256 一致。
- `~/Applications/AI Pulse.app` 已运行；保留 `dev.yuwangzhi.codexpulse`。原名称安装副本已备份，偏好中的 accounts、selectedAccountID、theme、compactStatus、projectDirectories 在更新前后逐字段散列一致。
- 安装后真实诊断：Codex 已连接且额度可用；CC Switch 只读查询成功；4 个中转 Key 的服务端额度可用（3 个 4Router、1 个 ZZS）。default / Claude Official 未接入额度查询，显示不支持而非零。
- 实际 GET 核验：两站 `/api/usage/token` 都返回 301 到 `/api/usage/token/`。程序使用带尾斜杠的规范路径，凭据请求仍不跟随重定向。公开 `/api/status` 用于核验额度单位和显示货币，不硬编码 500000 或 USD。
- 原生弹窗已点选验证：概览同时显示 Codex 额度 / Reset 与 CC 今日统计；「中转 / CC」页切换今日 / 7 天、按 ZZS 筛选后计数、费用、模型列表同步变化，ZZS 显示账户余额，4Router 显示 Key 累计消耗并明确缺少账户余额。数据刷新独立于 Codex 账户选择。
- 首次真实加载曾把滚动位置移到中间，已用顶部默认滚动锚点修复；真实页面重新截图核验。合成深色截图见 `relay-dark.png`，不含真实账户数据。
- 速度口径核验 CC Switch `response_processor.rs`：流结束后记录 `latency_ms`，因此可作总耗时；`duration_ms` 未填时回退该字段。首字后区间小于 250 ms 的记录不显示首字后吞吐，成功有效记录按总输出 Token / 总区间加权。实际 7 天界面有有效首字后吞吐，今日及 ZZS 请求因上游缓冲多为未知，未伪造为纯生成速度。
- 统计保守隔离：只计 `app_type=claude,data_source=proxy`，单列导入记录数，不把代理与会话记录相加，也不把 Codex 的本机日志再计入 CC 总计。
- 读取器不选择提示词、响应正文、错误正文或请求头。额度凭据临时从对应 provider 提取，只发往该已核验站点；不保存凭据、不把原始网络错误体输出到 UI / 诊断。

限制：只覆盖 CC Switch 保留且经过本地代理的 Claude Code 请求；不会恢复已清理历史，不合并会话导入记录。未实现 Claude 官方订阅额度或任意中转脚本。4Router 的当前 API Key 接口未返回账户余额，只能显示 Key 限额状态和累计消耗；ZZS 返回的账户余额可展示。费用是 CC Switch USD 估算，吞吐会受思考 Token、网络和上游缓冲影响，不代表纯解码速度。

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
