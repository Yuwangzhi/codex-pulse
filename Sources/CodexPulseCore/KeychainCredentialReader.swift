import Foundation
import Security
import Darwin

enum KeychainCredentialReadError: Error, Equatable {
    case authorization, notFound
}

/// Uses Apple's stable, already-authorized reader instead of granting each ad-hoc
/// build of AI Pulse a new Keychain identity. No passwords, ACLs or tokens are saved.
enum KeychainCredentialReader {
    static let executable = URL(fileURLWithPath: "/usr/bin/security")

    static func read(service: String, account: String? = nil, allowInteraction: Bool) throws -> Data {
        try read(service: service, account: account, allowInteraction: allowInteraction,
                 preflight: { try isAuthorized(service: service, account: account) },
                 execute: { arguments, timeout in
                     try run(executable: executable, arguments: arguments, timeout: timeout)
                 })
    }

    // Injectable boundaries keep tests away from the user's actual Keychain.
    static func read(service: String, account: String?, allowInteraction: Bool,
                     preflight: () throws -> Bool,
                     execute: ([String], TimeInterval) throws -> Data) throws -> Data {
        if !allowInteraction {
            guard try preflight() else { throw KeychainCredentialReadError.authorization }
        }
        var arguments = ["find-generic-password", "-s", service]
        if let account { arguments += ["-a", account] }
        arguments.append("-w")
        return try execute(arguments, allowInteraction ? 120 : 10)
    }

    private static func isAuthorized(service: String, account: String?) throws -> Bool {
        // Metadata only: this does not ask for the secret or change its access list.
        var item: SecKeychainItem?
        let status = SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service,
            UInt32(account?.utf8.count ?? 0), account, nil, nil, &item)
        if status == errSecItemNotFound { throw KeychainCredentialReadError.notFound }
        guard status == errSecSuccess, let item else { return false }
        var keychain: SecKeychain?
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess else { return false }
        var keychainStatus: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &keychainStatus) == errSecSuccess,
              keychainStatus & UInt32(kSecUnlockStateStatus) != 0 else { return false }

        // The path alone must not authorize a replacement executable.
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("identifier com.apple.security and anchor apple" as CFString,
                                             [], &requirement) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }

        var access: SecAccess?, list: CFArray?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &list) == errSecSuccess else { return false }
        for acl in (list as? [SecACL]) ?? [] {
            guard (SecACLCopyAuthorizations(acl) as? [String])?.contains(kSecACLAuthorizationDecrypt as String) == true else { continue }
            var applications: CFArray?, description: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess,
                  !prompt.contains(.requirePassphase) else { continue }
            // nil means this entry already allows every app; we never create such an entry.
            guard let applications else { return true }
            for application in (applications as? [SecTrustedApplication]) ?? [] {
                var data: CFData?
                guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data else { continue }
                let path = String(decoding: data as Data, as: UTF8.self).split(separator: "\0").first.map(String.init)
                if path == executable.path { return true }
            }
        }
        return false
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    outputLimit: Int = 1024 * 1024, input: Data? = nil,
                    environment: [String: String]? = nil, directory: URL? = nil) throws -> Data {
        let process = Process(), pipe = Pipe(), exited = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice as Any
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw KeychainCredentialReadError.authorization }
        if let input, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }

        let output = CredentialOutput(), drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    if !output.append(chunk, limit: outputLimit) {
                        if process.isRunning { process.terminate() }
                        break
                    }
                }
            } catch { output.fail() }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        let readFinished = drained.wait(timeout: .now() + 1) == .success
        defer { try? pipe.fileHandleForReading.close() }
        guard !timedOut, !process.isRunning, readFinished, process.terminationStatus == 0,
              var data = output.value(), !data.isEmpty else { throw KeychainCredentialReadError.authorization }
        // `security -w` adds one line terminator; preserve any newline in the secret itself.
        if data.last == 0x0A { data.removeLast() }
        guard !data.isEmpty else { throw KeychainCredentialReadError.authorization }
        return data
    }
}

private final class CredentialOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var failed = false
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failed, data.count + chunk.count <= limit else { failed = true; return false }
        data.append(chunk); return true
    }
    func fail() { lock.lock(); failed = true; lock.unlock() }
    func value() -> Data? { lock.lock(); defer { lock.unlock() }; return failed ? nil : data }
}
