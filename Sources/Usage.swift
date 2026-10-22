import Foundation

// Lê os logs locais do Claude Code (~/.claude/projects/**/*.jsonl) de forma incremental
// e extrai uso de tokens + o que o Claude está fazendo agora.

struct UsageEntry {
    let ts: Date
    let tokens: Int
    // Tokens ponderados pelo custo (cache lido pesa 0,1; saída pesa 5…), que é
    // o que mais se aproxima de como os limites do plano são consumidos.
    let units: Double
}

struct LastEvent {
    enum Kind { case user, assistantTool, assistantDone }
    let kind: Kind
    let ts: Date
    let toolName: String?
    let toolDetail: String?
    let project: String?
}

// Uma leitura real do /usage. Daqui pra frente o app soma só o que os logs mostram.
struct Calibration: Codable {
    var at: Date
    var sessionPct: Double
    var sessionResetsAt: Date
    var weekPct: Double
    var source: String? = "/usage"   // statusLine, /usage ou manual
}

struct Config: Codable {
    // Limites em unidades ponderadas, medidos contra o /usage em 22/10/2026.
    var sessionLimitUnits: Double = 18_000_000
    var weeklyLimitUnits: Double = 67_000_000
    // Com o Claude trabalhando, de quantos em quantos segundos ler o /usage real.
    var liveProbeSeconds: Double? = 60
    // Qualquer instante em que a semana renova; o ciclo se repete a cada 7 dias.
    var weekResetsAt: Date = ISO8601DateFormatter().date(from: "2026-10-24T12:59:00Z")!
    var calibration: Calibration? = Calibration(
        at: ISO8601DateFormatter().date(from: "2026-10-22T16:59:00Z")!,
        sessionPct: 0.16,
        sessionResetsAt: ISO8601DateFormatter().date(from: "2026-10-22T18:59:00Z")!,
        weekPct: 0.10, source: "/usage")

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claudinho/config.json")

    static func load() -> Config {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let cfg = try? dec.decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        cfg.save()
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: Self.url)
    }

    func weekWindow(at now: Date) -> DateInterval {
        let week: TimeInterval = 7 * 86400
        let k = ((now.timeIntervalSince(weekResetsAt)) / week).rounded(.down) + 1
        let end = weekResetsAt.addingTimeInterval(k * week)
        return DateInterval(start: end.addingTimeInterval(-week), end: end)
    }
}

struct Snapshot {
    var todayTokens = 0
    var avg7dTokens = 0
    var sessionPct = 0.0
    var sessionResetsAt: Date?
    var weekPct = 0.0
    var weekResetsAt: Date?
    var calibrated = false
    var last: LastEvent?
}

final class UsageReader {
    private var offsets: [URL: UInt64] = [:]
    private var entries: [String: UsageEntry] = [:]
    private var lastByFile: [URL: LastEvent] = [:]

    private let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".config/claude/projects")]
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac = ISO8601DateFormatter()

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    func refresh(config: Config, now: Date = Date()) -> Snapshot {
        let horizon = now.addingTimeInterval(-8 * 86400)
        for file in recentFiles(since: horizon) { readNew(file) }
        entries = entries.filter { $0.value.ts >= horizon }
        return snapshot(config: config, now: now)
    }

    func units(from: Date, to: Date) -> Double {
        entries.values.reduce(0) { $1.ts > from && $1.ts <= to ? $0 + $1.units : $0 }
    }

    private func recentFiles(since: Date) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots where fm.fileExists(atPath: root.path) {
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mod, mod >= since { out.append(url) }
            }
        }
        return out
    }

    private func readNew(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        let start = offsets[url] ?? 0
        let size = (try? fh.seekToEnd()) ?? 0
        if size < start { offsets[url] = 0; return } // arquivo reescrito: relê na próxima
        guard size > start else { return }
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNL]
        offsets[url] = start + UInt64(complete.count)

        for line in complete.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            parse(obj, file: url)
        }
    }

    private static func weigh(_ usage: [String: Any], model: String) -> (Int, Double) {
        func n(_ k: String) -> Int { (usage[k] as? Int) ?? 0 }
        let input = n("input_tokens"), output = n("output_tokens")
        let write = n("cache_creation_input_tokens"), read = n("cache_read_input_tokens")
        let write1h = ((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int) ?? 0
        let tokens = input + output + write + read
        let modelWeight = model.contains("haiku") ? 0.2 : model.contains("sonnet") ? 0.6 : 1.0
        let units = (Double(input) + 5 * Double(output) + 1.25 * Double(write - write1h)
                     + 2 * Double(write1h) + 0.1 * Double(read)) * modelWeight
        return (tokens, units)
    }

    private func parse(_ obj: [String: Any], file: URL) {
        guard let type = obj["type"] as? String, let ts = Self.date(obj["timestamp"]) else { return }
        let msg = obj["message"] as? [String: Any]
        let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }

        if type == "assistant", let msg {
            if let usage = msg["usage"] as? [String: Any] {
                let (tokens, units) = Self.weigh(usage, model: msg["model"] as? String ?? "")
                // Uma resposta vira várias linhas (uma por bloco) repetindo o mesmo usage: deduplica.
                let id = "\(msg["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"
                entries[id] = UsageEntry(ts: ts, tokens: tokens, units: units)
            }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                lastByFile[file] = LastEvent(kind: .assistantTool, ts: ts,
                                             toolName: tool["name"] as? String,
                                             toolDetail: Self.detail(tool["input"] as? [String: Any]),
                                             project: project)
            } else if msg["stop_reason"] as? String == "end_turn" {
                lastByFile[file] = LastEvent(kind: .assistantDone, ts: ts, toolName: nil, toolDetail: nil, project: project)
            }
        } else if type == "user", obj["isMeta"] as? Bool != true {
            lastByFile[file] = LastEvent(kind: .user, ts: ts, toolName: nil, toolDetail: nil, project: project)
        }
    }

    private static func detail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["description", "command", "file_path", "pattern", "url", "query", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty {
                let s = key == "file_path" ? URL(fileURLWithPath: v).lastPathComponent : v
                return s.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return nil
    }

    // Janela de 5h estimada só pelos logs: começa na hora cheia da primeira mensagem.
    private func localSessionWindow(now: Date) -> DateInterval? {
        let cal = Calendar.current
        let recent = entries.values.filter { $0.ts >= now.addingTimeInterval(-10 * 3600) }.sorted { $0.ts < $1.ts }
        var start: Date?
        for e in recent where start == nil || e.ts >= start!.addingTimeInterval(5 * 3600) {
            start = cal.dateInterval(of: .hour, for: e.ts)?.start ?? e.ts
        }
        guard let start, now < start.addingTimeInterval(5 * 3600) else { return nil }
        return DateInterval(start: start, duration: 5 * 3600)
    }

    private func snapshot(config: Config, now: Date) -> Snapshot {
        var s = Snapshot()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let prev7 = cal.date(byAdding: .day, value: -7, to: today)!

        var prevSum = 0
        for e in entries.values {
            if e.ts >= today { s.todayTokens += e.tokens }
            else if e.ts >= prev7 { prevSum += e.tokens }
        }
        s.avg7dTokens = prevSum / 7

        let c = config.calibration
        if let c, now < c.sessionResetsAt {
            s.sessionPct = c.sessionPct + units(from: c.at, to: now) / config.sessionLimitUnits
            s.sessionResetsAt = c.sessionResetsAt
            s.calibrated = true
        } else if let w = localSessionWindow(now: now) {
            s.sessionPct = units(from: w.start, to: now) / config.sessionLimitUnits
            s.sessionResetsAt = w.end
        }

        let week = config.weekWindow(at: now)
        s.weekResetsAt = week.end
        if let c, c.at >= week.start {
            s.weekPct = c.weekPct + units(from: c.at, to: now) / config.weeklyLimitUnits
        } else {
            s.weekPct = units(from: week.start, to: now) / config.weeklyLimitUnits
        }
        s.sessionPct = min(1, s.sessionPct)
        s.weekPct = min(1, s.weekPct)

        s.last = lastByFile.values.max { $0.ts < $1.ts }
        return s
    }
}
