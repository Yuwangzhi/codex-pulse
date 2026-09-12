import AppKit

extension MonitorStore {
    func projectDirectory(for original: String) -> String {
        projectDirectories[original] ?? original
    }

    func openProjectInFinder(_ original: String) {
        guard !openingProject, !isPresentingDialog else { return }
        let path = projectDirectory(for: original)
        guard isDirectory(path) else {
            isPresentingDialog = true
            let alert = NSAlert()
            alert.messageText = "项目目录不存在"
            alert.informativeText = "此任务记录的目录可能已移动或删除：\n\(path.isEmpty ? "（未记录路径）" : path)\n\n选择新位置后，会记住它，并用于所有记录了同一旧路径的任务。"
            alert.addButton(withTitle: "选择新位置…")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            isPresentingDialog = false
            if response == .alertFirstButtonReturn { chooseProjectDirectory(original) }
            return
        }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            showProjectError("无法找到 Finder。")
            return
        }
        openingProject = true
        let request = UUID()
        projectOpenRequest = request
        // Leave the SwiftUI / accessibility action before asking Launch Services to open a folder.
        DispatchQueue.main.async { [weak self] in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)],
                                    withApplicationAt: finder, configuration: configuration) { app, error in
                Task { @MainActor in
                    guard let self, self.projectOpenRequest == request else { return }
                    self.projectOpenRequest = nil
                    self.openingProject = false
                    if let error {
                        self.showProjectError("\(path)\n\n\(error.localizedDescription)")
                    } else if app == nil {
                        self.showProjectError("Finder 未能打开：\n\(path)")
                    } else {
                        self.dismissPanel?()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.projectOpenRequest == request else { return }
            self.projectOpenRequest = nil
            self.openingProject = false
            self.showProjectError("macOS 在 10 秒内没有返回打开结果，可能正在等待文件访问授权。\n\n\(path)\n\n如有系统权限提示，请先处理后重试；原打开请求仍可能稍后完成。")
        }
    }

    func chooseProjectDirectory(_ original: String) {
        guard !openingProject, !isPresentingDialog else { return }
        isPresentingDialog = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此目录"
        panel.message = "选择项目现在所在的文件夹。仅更新 Codex Pulse 的目录映射，不修改 Codex 会话记录。"
        let path = projectDirectory(for: original)
        var start = path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.homeDirectoryForCurrentUser
        while !isDirectory(start.path), start.path != "/" { start.deleteLastPathComponent() }
        panel.directoryURL = start
        panel.begin { [weak self] response in
            guard let self else { return }
            self.isPresentingDialog = false
            guard response == .OK, let url = panel.url, self.isDirectory(url.path) else { return }
            self.projectDirectories[original] = url.path
            if !self.isDemo { UserDefaults.standard.set(self.projectDirectories, forKey: "projectDirectories") }
            self.openProjectInFinder(original)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func showProjectError(_ message: String) {
        isPresentingDialog = true
        defer { isPresentingDialog = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法在 Finder 中打开"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
