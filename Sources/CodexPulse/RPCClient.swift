import Foundation

@MainActor
final class RPCClient {
    var onReady: (() -> Void)?
    var onDisconnect: ((String) -> Void)?
    var onNotification: ((String, [String: Any]) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var generation = UUID()
    private var pending: [Int: (Result<Data, Error>) -> Void] = [:]
    private(set) var ready = false
    private(set) var executablePath: String?

    enum RPCError: LocalizedError {
        case failure(String)
        var errorDescription: String? { if case .failure(let text) = self { return text }; return nil }
    }

    static func locateCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let custom = UserDefaults.standard.string(forKey: "codexExecutable"), !custom.isEmpty { candidates.append(custom) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/codex" }
        }
        candidates += [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                       "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func start(home: URL) {
        stop()
        guard let executable = Self.locateCLI() else {
            onDisconnect?("找不到 Codex CLI，请在设置中选择 codex 可执行文件。")
            return
        }
        executablePath = executable.path
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.arguments = ["app-server", "--listen", "stdio://"]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        task.environment = environment
        // Do not inherit the current workspace as a trust/config scope.
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let currentGeneration = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                if !data.isEmpty { self.receive(data) }
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.stop(); self.onDisconnect?("Codex 连接已断开，将自动重连。")
            }
        }
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do {
            try task.run()
            request("initialize", params: ["clientInfo": ["name": "codex_pulse", "version": "0.2.1"],
                                           "capabilities": ["experimentalApi": true]]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.send(["method": "initialized", "params": [:]])
                    self.ready = true; self.onReady?()
                case .failure:
                    self.stop(); self.onDisconnect?("Codex 初始化失败或超时，将自动重连。")
                }
            }
        } catch {
            stop(); onDisconnect?("无法启动 Codex CLI，请检查设置中的路径。")
        }
    }

    func request(_ method: String, params: [String: Any]? = nil, completion: @escaping (Result<Data, Error>) -> Void) {
        guard process?.isRunning == true else { completion(.failure(RPCError.failure("Codex 尚未连接"))); return }
        nextID += 1; let id = nextID
        pending[id] = completion
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        send(message)
        let currentGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.pending.removeValue(forKey: id)?(.failure(RPCError.failure("请求超时，保留上次数据")))
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        do { try input?.write(contentsOf: data) }
        catch { stop(); onDisconnect?("Codex 连接写入失败，将自动重连。") }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                if message["error"] != nil {
                    // Backend errors can contain private request context. Keep UI and diagnostics generic.
                    callback(.failure(RPCError.failure("接口暂不可用，请确认 Codex 已登录且账号支持此功能。")))
                } else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                    callback(.success(data))
                } else { callback(.failure(RPCError.failure("Codex 返回了无法识别的数据。"))) }
            } else if let method = message["method"] as? String, message["id"] == nil {
                onNotification?(method, message["params"] as? [String: Any] ?? [:])
            }
        }
    }

    func stop() {
        generation = UUID(); ready = false
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; buffer.removeAll()
        let callbacks = Array(pending.values); pending.removeAll()
        for callback in callbacks { callback(.failure(RPCError.failure("连接已关闭"))) }
    }
}
