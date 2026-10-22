import Foundation

// O que o app manda pro widget. O widget roda em sandbox, então não lê os históricos nem
// roda o /usage: só lê este arquivo, que o app grava em ~/.claudinho/widget.json.
struct WidgetSnapshot: Codable, Equatable {
    var updatedAt: Date
    var state: ChefState
    var sessionPct: Double
    var sessionResetsAt: Date?
    var weekPct: Double
    var weekResetsAt: Date?
    var todayTokens: Int
    var avg7dTokens: Int
    var toolName: String?
    var toolDetail: String?
    var project: String?
    var liveAt: Date?          // última leitura real (/usage, statusLine ou manual)

    static let placeholder = WidgetSnapshot(
        updatedAt: Date(), state: .thinking, sessionPct: 0.13, sessionResetsAt: Date().addingTimeInterval(2 * 3600),
        weekPct: 0.31, weekResetsAt: Date().addingTimeInterval(2 * 86400), todayTokens: 147_700_000,
        avg7dTokens: 98_300_000, toolName: "Bash", toolDetail: "Roda os testes", project: "claudinho-widget", liveAt: Date())

    // Dentro do sandbox, homeDirectoryForCurrentUser é o container do widget, não a sua pasta.
    static var url: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDINHO_DIR"] { return URL(fileURLWithPath: d).appendingPathComponent("widget.json") }
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claudinho/widget.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = .sortedKeys; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    // O que muda o desenho do widget. Segundos de diferença no horário não contam.
    func looksDifferent(from o: WidgetSnapshot) -> Bool {
        state != o.state || Int((sessionPct * 100).rounded()) != Int((o.sessionPct * 100).rounded())
            || Int((weekPct * 100).rounded()) != Int((o.weekPct * 100).rounded())
            || toolName != o.toolName || project != o.project || sessionResetsAt != o.sessionResetsAt
            || todayTokens / 1_000_000 != o.todayTokens / 1_000_000
    }

    // App fechado ou Mac dormindo: o widget não finge que está ao vivo.
    func current(now: Date = Date()) -> WidgetSnapshot {
        var s = self
        if now.timeIntervalSince(updatedAt) > 15 * 60 { s.state = .resting; s.toolName = nil; s.toolDetail = nil }
        if let r = sessionResetsAt, r < now { s.sessionPct = 0; s.sessionResetsAt = nil }
        return s
    }
}
