import Foundation
import Testing
@testable import CodexPulseCore

@Test func unapprovedBackgroundKeychainReadNeverLaunchesSecurity() {
    var launched = false
    #expect(throws: KeychainCredentialReadError.authorization) {
        try KeychainCredentialReader.read(service: "synthetic", account: nil, allowInteraction: false,
            preflight: { false }, execute: { _, _ in launched = true; return Data("secret".utf8) })
    }
    #expect(!launched)
}

@Test func approvedKeychainReadUsesOnlyExactServiceAndAccount() throws {
    let value = try KeychainCredentialReader.read(service: "Claude Code-credentials", account: "synthetic-user",
        allowInteraction: false, preflight: { true }, execute: { arguments, timeout in
            #expect(arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-a", "synthetic-user", "-w"])
            #expect(timeout == 10)
            return Data("synthetic".utf8)
        })
    #expect(value == Data("synthetic".utf8))
}

@Test func onlyExplicitInteractionCanRequestAnUnapprovedKeychainRead() throws {
    var inspected = false
    _ = try KeychainCredentialReader.read(service: "synthetic", account: nil, allowInteraction: true,
        preflight: { inspected = true; return false }, execute: { arguments, timeout in
            #expect(arguments == ["find-generic-password", "-s", "synthetic", "-w"])
            #expect(timeout == 120)
            return Data("synthetic".utf8)
        })
    #expect(!inspected)
}

@Test func keychainReaderPreservesSecretNewlinesAndRejectsFailures() throws {
    let printf = URL(fileURLWithPath: "/usr/bin/printf")
    let data = try KeychainCredentialReader.run(executable: printf, arguments: ["synthetic\n\n"], timeout: 2)
    #expect(data == Data("synthetic\n".utf8))
    #expect(throws: KeychainCredentialReadError.authorization) {
        try KeychainCredentialReader.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf synthetic-secret; exit 1"], timeout: 2)
    }
    #expect(throws: KeychainCredentialReadError.authorization) {
        try KeychainCredentialReader.run(executable: printf, arguments: [String(repeating: "x", count: 1024)],
                                        timeout: 2, outputLimit: 128)
    }
}

@Test func stalledCredentialReaderIsTerminatedInsteadOfBlockingRefresh() {
    let start = Date()
    #expect(throws: KeychainCredentialReadError.authorization) {
        try KeychainCredentialReader.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                        arguments: ["10"], timeout: 0.05)
    }
    #expect(Date().timeIntervalSince(start) < 3)
}
