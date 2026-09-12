import Foundation
import Testing
@testable import CodexPulseCore

private func session(_ id: String, _ state: TaskState, _ tokens: Int64, _ time: Double) -> SessionInfo {
    var item = SessionInfo(id: id, title: "验证数据", cwd: "/Projects/Pipeline", model: "Codex", rolloutPath: "", updatedAt: Date(timeIntervalSince1970: time), totalTokens: tokens)
    item.state = state
    return item
}

@Test func searchMatchesAcrossFieldsAndCombinesWithState() {
    let all = [session("a", .running, 10, 1), session("b", .completed, 20, 2)]
    let result = SessionQuery.results(all, search: "验证 pipeline CODEX", state: .running, sort: .activity)
    #expect(result.map(\.id) == ["a"])
    #expect(SessionQuery.results(all, search: "missing", state: nil, sort: .recent).isEmpty)
    #expect(SessionQuery.results(all, search: " \n ", state: nil, sort: .recent).count == 2)
}

@Test func activitySortKeepsRunningAheadOfNewerCompletedTasks() {
    let all = [session("done", .completed, 900, 300), session("run", .running, 10, 100), session("quiet", .quiet, 30, 200)]
    #expect(SessionQuery.results(all, search: "", state: nil, sort: .activity).map(\.id) == ["run", "quiet", "done"])
    #expect(SessionQuery.results(all, search: "", state: nil, sort: .recent).map(\.id) == ["done", "quiet", "run"])
}

@Test func tokensSortAndEqualTimestampsHaveStableOrder() {
    let all = [session("b", .running, 100, 1), session("a", .running, 100, 1), session("c", .completed, 1000, 0)]
    #expect(SessionQuery.results(all, search: "", state: nil, sort: .tokens).map(\.id) == ["c", "a", "b"])
}
