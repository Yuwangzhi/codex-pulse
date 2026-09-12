import Foundation

public enum SessionSort: String, CaseIterable {
    case activity = "任务状态"
    case recent = "最近更新"
    case tokens = "Token 用量"
}

public enum SessionQuery {
    public static func results(_ sessions: [SessionInfo], search: String, state: TaskState?, sort: SessionSort) -> [SessionInfo] {
        let words = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return sessions.filter { session in
            guard state == nil || session.state == state else { return false }
            let text = [session.title, session.cwd, session.model, session.id].joined(separator: " ")
            return words.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.sorted { a, b in
            if sort == .tokens, a.totalTokens != b.totalTokens { return a.totalTokens > b.totalTokens }
            if sort == .activity {
                let order: [TaskState: Int] = [.running: 0, .quiet: 1, .interrupted: 2, .unknown: 3, .completed: 4]
                if order[a.state] != order[b.state] { return order[a.state, default: 3] < order[b.state, default: 3] }
            }
            let aDate = a.lastEventAt ?? a.updatedAt, bDate = b.lastEventAt ?? b.updatedAt
            if aDate != bDate { return aDate > bDate }
            return a.id < b.id
        }
    }
}
