import Foundation

// Lê o /usage de verdade rodando `claude "/usage"` escondido num pseudo-terminal
// (via /usr/bin/script), por poucos segundos, e mata o processo assim que os números aparecem.
// O Claude Code abre só a tela de uso: não chama o modelo nem grava sessão.

struct UsageReading {
    let sessionPct: Double
    let sessionResetsAt: Date
    let weekPct: Double
}

enum UsageProbe {
    static let workDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudinho")

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Bloqueia até ~15s; chame fora da thread principal.
    static func read() -> UsageReading? {
        guard let claude = claudePath() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", claude, "/usage"]
        p.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "120"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin   // fica aberto: se o stdin fechar, o claude sai antes de desenhar
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data()
        var result: UsageReading?
        let done = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            guard result == nil, !chunk.isEmpty else { return }
            buffer.append(chunk)
            if let r = parse(String(decoding: buffer, as: UTF8.self)) { result = r; done.signal() }
        }
        do { try p.run() } catch { return nil }
        _ = done.wait(timeout: .now() + 15)
        stdout.fileHandleForReading.readabilityHandler = nil
        if p.isRunning {
            // Mata o claude (filho do script) e depois o script.
            let pk = Process()
            pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pk.arguments = ["-TERM", "-P", "\(p.processIdentifier)"]
            try? pk.run(); pk.waitUntilExit()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        try? stdin.fileHandleForWriting.close()
        lock.lock(); defer { lock.unlock() }
        return result
    }

    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{1B}\\[\\d*[GC]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?<>=]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][A-Z0-9]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func parse(_ raw: String) -> UsageReading? {
        let text = clean(raw)
        guard let s = text.range(of: "Current session", options: .backwards),
              let w = text.range(of: "Current week", options: .backwards), s.upperBound < w.lowerBound else { return nil }
        let sessionPart = String(text[s.upperBound..<w.lowerBound])
        let weekPart = String(text[w.upperBound...])
        guard let sp = firstMatch(#"(\d+)\s*%\s*used"#, in: sessionPart),
              let wp = firstMatch(#"(\d+)\s*%\s*used"#, in: weekPart) else { return nil }
        // Sem sessão ativa não há "Resets": a leitura vale só pra semana.
        let reset = firstMatch(#"Resets\s*(\d{1,2}(?::\d{2})?\s*[ap]m)"#, in: sessionPart).flatMap { nextClockTime($0) } ?? Date()
        return UsageReading(sessionPct: Double(sp)! / 100, sessionResetsAt: reset, weekPct: Double(wp)! / 100)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // "9pm" / "8:59 pm" -> próxima vez que o relógio marcar esse horário.
    static func nextClockTime(_ t: String, after now: Date = Date()) -> Date? {
        let lower = t.lowercased().replacingOccurrences(of: " ", with: "")
        let pm = lower.hasSuffix("pm")
        let nums = lower.dropLast(2).split(separator: ":").compactMap { Int($0) }
        guard let h12 = nums.first, h12 >= 1, h12 <= 12 else { return nil }
        let hour = (h12 % 12) + (pm ? 12 : 0)
        let minute = nums.count > 1 ? nums[1] : 0
        return Calendar.current.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                         matchingPolicy: .nextTime)
    }
}
