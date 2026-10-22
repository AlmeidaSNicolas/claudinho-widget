import Foundation

// Lê o que hooks/hook.py e hooks/statusline.py gravaram em ~/.claudinho.
// Os dois são opcionais (python3 setup.py): sem eles o Claudinho vive só dos logs.

struct HookSession {
    let status: String          // working, asking, waiting, done, closed
    let toolRunning: Bool
    let toolName: String?
    let toolDesc: String?
    let project: String?
    let lastEvent: Date
}

struct RateLimits {
    let savedAt: Date
    let sessionPct: Double
    let sessionResetsAt: Date?
    let weekPct: Double
    let weekResetsAt: Date?
}

enum HookFiles {
    static let dir = ProcessInfo.processInfo.environment["CLAUDINHO_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudinho")

    private static func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func sessions() -> [HookSession] {
        let raw = json("state.json")?["sessions"] as? [String: [String: Any]] ?? [:]
        return raw.values.compactMap { s in
            guard let t = s["last_event"] as? Double, let status = s["status"] as? String else { return nil }
            return HookSession(status: status, toolRunning: s["tool_running"] as? Bool ?? false,
                               toolName: s["tool_name"] as? String, toolDesc: s["tool_desc"] as? String,
                               project: s["project"] as? String, lastEvent: Date(timeIntervalSince1970: t))
        }
    }

    // A sessão que mais importa agora: pedindo permissão > trabalhando > terminou > esperando.
    static func mostUrgent(_ sessions: [HookSession], now: Date = Date()) -> HookSession? {
        func rank(_ s: HookSession) -> Int {
            switch s.status {
            case "asking": 4
            case "working": 3
            case "done": 2
            case "waiting": 1
            default: 0
            }
        }
        return sessions
            .filter { $0.status != "closed" && now.timeIntervalSince($0.lastEvent) < 30 * 60 }
            .max { (rank($0), $0.lastEvent) < (rank($1), $1.lastEvent) }
    }

    // resets_at pode vir como epoch (s) ou texto ISO, dependendo da versão do Claude Code.
    private static func date(_ v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    static func rateLimits() -> RateLimits? {
        guard let obj = json("statusline.json"), let saved = obj["saved_at"] as? Double,
              let rl = obj["rate_limits"] as? [String: Any],
              let five = rl["five_hour"] as? [String: Any], let week = rl["seven_day"] as? [String: Any],
              let sp = five["used_percentage"] as? Double, let wp = week["used_percentage"] as? Double else { return nil }
        return RateLimits(savedAt: Date(timeIntervalSince1970: saved),
                          sessionPct: sp / 100, sessionResetsAt: date(five["resets_at"]),
                          weekPct: wp / 100, weekResetsAt: date(week["resets_at"]))
    }
}
