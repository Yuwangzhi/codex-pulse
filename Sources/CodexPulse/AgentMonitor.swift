import AppKit
import Combine
import CodexPulseCore
import Darwin

enum AgentHookCommand {
    /// Runs before NSApplication is created: hooks are fast local writes, never GUI launches.
    static func handle(_ args: [String]) -> Bool {
        if let index = args.firstIndex(of: AgentHooks.marker) {
            guard args.count > index + 1, let agent = MonitoredAgent(rawValue: args[index + 1]) else { return true }
            var data = Data()
            while data.count <= 2 * 1024 * 1024 {
                let chunk = FileHandle.standardInput.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            if let event = AgentHookEvent(data: data, agent: agent, environment: ProcessInfo.processInfo.environment) {
                try? AgentSessionFiles.record(event, ownerPID: ownerPID(agent))
            }
            // No stdout/stderr or approval decisions, even if recording fails.
            return true
        }
        if args.contains("--install-agent-hooks") || args.contains("--remove-agent-hooks") {
            guard let executable = Bundle.main.executableURL else { Darwin.exit(1) }
            do {
                for agent in MonitoredAgent.allCases {
                    try AgentHooks.configure(agent: agent, executable: executable, enabled: args.contains("--install-agent-hooks"))
                }
                print("AI Pulse: agent hooks updated")
            } catch {
                print("AI Pulse: configuration could not be updated; existing files preserved")
                Darwin.exit(1)
            }
            return true
        }
        return false
    }

    private static func ownerPID(_ agent: MonitoredAgent) -> Int32? {
        // Process names only, never argv (which can contain user prompts and credentials).
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,comm="]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var parents: [Int32: (Int32, String)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) {
                parents[pid] = (parent, String(fields[2]))
            }
        }
        var pid = getppid()
        for _ in 0..<12 {
            guard let (parent, path) = parents[pid] else { break }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if name == agent.rawValue || (agent == .claude && path.contains("/claude/versions/")) { return pid }
            if parent <= 1 || parent == pid { break }; pid = parent
        }
        return nil
    }
}

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var records: [AgentSession] = []
    @Published private(set) var error: String?
    @Published private(set) var hookStatus: [MonitoredAgent: Bool] = [:]
    @Published private(set) var setupMessage: String?
    @Published private(set) var grokBot: GrokBotSnapshot?
    @Published private(set) var grokBotError: String?
    var grokBotRunning: Bool { grokBot.map { kill($0.pid, 0) == 0 || errno == EPERM } ?? false }
    private var reading = false
    private var stopped = false
    private let demo: Bool
    private var lastHookCheck = Date.distantPast

    init(demo: Bool) {
        self.demo = demo
        if demo {
            records = [
                AgentSession(agent: .grok, sessionID: "demo-grok", cwd: "/demo/strategy-lab", phase: .attention, updatedAt: Date(), tool: "ask_user_question"),
                AgentSession(agent: .claude, sessionID: "demo-claude", cwd: "/demo/manuscript", phase: .running, updatedAt: Date(), tool: "Bash"),
                AgentSession(agent: .grok, sessionID: "demo-grok-done", cwd: "/demo/data-tools", phase: .completed, updatedAt: Date().addingTimeInterval(-35))
            ]
            hookStatus = [.claude: true, .grok: true]
            grokBot = GrokBotSnapshot(pid: getpid(), appVersion: "演示", signedIn: true,
                                     quota: GrokBotQuota(usedPercent: 14, resetAt: Date().addingTimeInterval(86400 * 3),
                                                        readAt: Date().addingTimeInterval(-360)))
        }
    }
    func refresh() {
        guard !demo, !reading, !stopped else { return }
        reading = true
        if Date().timeIntervalSince(lastHookCheck) > 60 { checkHooks() }
        Task {
            let (result, desktop) = await Task.detached(priority: .utility) {
                (Result { try AgentSessionFiles.read() }, Result { try GrokBotReader.read() })
            }.value
            guard !stopped else { reading = false; return }
            switch result {
            case .success(let rows): records = rows; error = nil
            case .failure: error = "会话状态暂时无法读取，稍后自动重试。"
            }
            switch desktop {
            case .success(let snapshot): grokBot = snapshot; grokBotError = nil
            case .failure: grokBot = nil; grokBotError = "Grok Bot 本地缓存暂不可读。"
            }
            reading = false
        }
    }
    func stop() { stopped = true }
    func checkHooks() {
        guard !demo, let executable = Bundle.main.executableURL else { return }
        hookStatus = Dictionary(uniqueKeysWithValues: MonitoredAgent.allCases.map {
            ($0, AgentHooks.installed(agent: $0, executable: executable))
        })
        lastHookCheck = Date()
    }
    func configure(_ agent: MonitoredAgent, enabled: Bool) {
        guard !demo, let executable = Bundle.main.executableURL else { return }
        do {
            try AgentHooks.configure(agent: agent, executable: executable, enabled: enabled)
            setupMessage = enabled ? "\(agent.label) 监控已启用。新开一个会话后生效。" : "\(agent.label) 的状态采集已移除。"
        } catch { setupMessage = "配置更新失败，原文件已保留。请检查文件权限及 JSON 格式。" }
        checkHooks()
    }
    func traffic(now: Date) -> [TrafficSession] {
        records.compactMap { record in
            guard demo || hookStatus[record.agent] == true else { return nil }
            let alive = record.ownerPID.map { kill($0, 0) == 0 || errno == EPERM }
            let phase = error == nil ? record.observedPhase(now: now, ownerAlive: alive) : .unknown
            // Closed and old sessions should not remain indefinitely on screen.
            if phase == .ended { return nil }
            let ongoing = record.phase == .running || record.phase == .attention
            if now.timeIntervalSince(record.updatedAt) > 3600 && !(ongoing && alive == true) { return nil }
            let detail = phase == .unknown ? "暂无新事件，可能仍在运行" : (record.tool ?? phase.label)
            return TrafficSession(id: record.id, agent: record.agent.label, project: record.project,
                                  cwd: record.cwd, phase: phase, detail: detail, updatedAt: record.updatedAt)
        }
    }
}
