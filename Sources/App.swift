import SwiftUI
import AppKit

// Separado do Monitor pra que só o desenho do chef redesenhe a cada quadro, não o painel inteiro.
final class Ticker: ObservableObject {
    @Published var frame = 0
}

final class Monitor: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var hook: HookSession?
    let ticker = Ticker()
    @Published var config = Config.load()
    @Published var calibrating = false

    @Published var probing = false
    var panelOpen = false

    private let reader = UsageReader()
    private let queue = DispatchQueue(label: "claudinho.reader")
    private var timers: [Timer] = []
    private var lastProbe = Date.distantPast
    private var demoState: ChefState?
    private var ignoredStatusLineAt: Date?
    private var watcher: DispatchSourceFileSystemObject?
    var isDemo: Bool { demoState != nil }
    private var timersStarted = false

    init() {
        timersStarted = true
        refresh()
        // Só anima (e redesenha) quando tem algo acontecendo ou o painel está aberto.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.panelOpen || self.state.animated else { return }
            self.ticker.frame += 1
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() })
        timers.forEach { $0.tolerance = 0.2; RunLoop.main.add($0, forMode: .common) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        watchHookFiles()
    }

    // Os hooks gravam com os.replace, o que muda a pasta: dá pra reagir na hora, sem esperar o timer.
    private func watchHookFiles() {
        try? FileManager.default.createDirectory(at: HookFiles.dir, withIntermediateDirectories: true)
        let fd = open(HookFiles.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        var pending = false
        src.setEventHandler { [weak self] in
            guard !pending else { return }   // junta rajadas de eventos numa leitura só
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pending = false; self?.refresh() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // Pra gerar as imagens do README e pros testes: sem timers e sem ler nada sozinho.
    // Com state nil, o estado é calculado de verdade a partir do snapshot e do hook.
    init(demo state: ChefState?, snapshot: Snapshot, hook: HookSession? = nil) {
        demoState = state
        self.snapshot = snapshot
        self.hook = hook
    }

    // O % só anda quando o Claude responde, então o /usage real é lido logo depois de atividade:
    // a cada 60 s enquanto trabalha e 15 s depois de terminar. Parado, não lê nada.
    // Roda mesmo com statusLine, porque no app do Claude ela pode repetir um % antigo.
    private func probeIfDue() {
        guard !probing, let last = lastActivity, last > lastProbe else { return }
        let finished = [.plating, .waiting, .resting].contains(state)
        let every = finished ? 15 : (config.liveProbeSeconds ?? 60)
        guard Date().timeIntervalSince(lastProbe) >= every else { return }
        probeNow()
    }

    func probeNow() {
        guard !probing else { return }
        probing = true
        lastProbe = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reading = UsageProbe.read()
            DispatchQueue.main.async {
                self?.probing = false
                if let r = reading {
                    self?.calibrate(sessionPct: r.sessionPct, weekPct: r.weekPct, sessionResetsAt: r.sessionResetsAt, source: "/usage")
                }
            }
        }
    }

    func refresh() {
        guard timersStarted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let cfg = Config.load()
            let snap = self.reader.refresh(config: cfg)
            let hook = HookFiles.mostUrgent(HookFiles.sessions())
            let rl = HookFiles.rateLimits()
            DispatchQueue.main.async {
                self.snapshot = snap; self.config = cfg; self.hook = hook
                // statusLine nova: é o % exato, vira a âncora da conta.
                // (+1 s porque o config.json guarda as datas sem frações de segundo)
                if let rl, let reset = rl.sessionResetsAt, reset > Date(),
                   rl.savedAt > (cfg.calibration?.at ?? .distantPast).addingTimeInterval(1),
                   rl.savedAt != self.ignoredStatusLineAt {
                    self.calibrate(sessionPct: rl.sessionPct, weekPct: rl.weekPct, sessionResetsAt: reset,
                                   weekResetsAt: rl.weekResetsAt, at: rl.savedAt, source: "statusLine")
                } else {
                    self.probeIfDue()
                }
            }
        }
    }

    // Grava uma leitura real do uso. Se a anterior era da mesma janela e o % andou,
    // aproveita pra medir de novo quanto vale 1% (média com o valor antigo).
    func calibrate(sessionPct: Double, weekPct: Double, sessionResetsAt: Date, weekResetsAt: Date? = nil,
                   at: Date = Date(), source: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var cfg = Config.load()
            // Dentro da mesma janela o uso só sobe: leitura menor que a anterior é velha.
            if source != "manual", let old = cfg.calibration,
               abs(old.sessionResetsAt.timeIntervalSince(sessionResetsAt)) < 120,
               sessionPct < old.sessionPct - 0.005 || weekPct < old.weekPct - 0.005 {
                DispatchQueue.main.async { self.ignoredStatusLineAt = at }
                return
            }
            // Limite só é remedido entre leituras do /usage ou manuais: a statusLine pode estar velha.
            if let old = cfg.calibration, at > old.at, old.source != "statusLine", source != "statusLine" {
                let used = self.reader.units(from: old.at, to: at)
                let ds = sessionPct - old.sessionPct
                if abs(old.sessionResetsAt.timeIntervalSince(sessionResetsAt)) < 120, ds >= 0.03, used > 0 {
                    cfg.sessionLimitUnits = (cfg.sessionLimitUnits + used / ds) / 2
                }
                let dw = weekPct - old.weekPct
                if cfg.weekWindow(at: old.at).end == cfg.weekWindow(at: at).end, dw >= 0.02, used > 0 {
                    cfg.weeklyLimitUnits = (cfg.weeklyLimitUnits + used / dw) / 2
                }
            }
            if let weekResetsAt { cfg.weekResetsAt = weekResetsAt }
            cfg.calibration = Calibration(at: at, sessionPct: sessionPct, sessionResetsAt: sessionResetsAt,
                                          weekPct: weekPct, source: source)
            cfg.save()
            let snap = self.reader.refresh(config: cfg)
            DispatchQueue.main.async { self.config = cfg; self.snapshot = snap; self.calibrating = false }
        }
    }

    private var lastActivity: Date? {
        [snapshot.last?.ts, hook?.lastEvent].compactMap { $0 }.max()
    }

    private static func toolState(_ name: String) -> ChefState {
        switch name {
        case "Bash": .frying
        case "Edit", "Write", "MultiEdit", "NotebookEdit": .chopping
        case "AskUserQuestion", "ExitPlanMode": .waiting
        default: .seasoning
        }
    }

    // Hooks quando existem (sabem de permissão e de várias sessões); senão, os logs.
    var state: ChefState {
        if let demoState { return demoState }
        let now = Date()
        if let h = hook, h.lastEvent >= (snapshot.last?.ts ?? .distantPast).addingTimeInterval(-5) {
            let age = now.timeIntervalSince(h.lastEvent)
            switch h.status {
            case "asking": return .asking
            case "working": return h.toolRunning ? Self.toolState(h.toolName ?? "") : .thinking
            case "done": return age < 90 ? .plating : .waiting
            default: return .waiting
            }
        }
        guard let last = snapshot.last else { return .resting }
        let age = now.timeIntervalSince(last.ts)
        if age > 15 * 60 { return .resting }
        switch last.kind {
        case .user: return .thinking
        case .assistantDone: return age < 90 ? .plating : .waiting
        case .assistantTool: return Self.toolState(last.toolName ?? "")
        }
    }

    private var useHook: Bool {
        guard let h = hook else { return false }
        return h.lastEvent >= (snapshot.last?.ts ?? .distantPast).addingTimeInterval(-5)
    }
    var toolName: String? { useHook ? (hook!.toolRunning ? hook!.toolName : nil) : snapshot.last?.toolName }
    var toolDetail: String? { useHook ? (hook!.toolRunning ? hook!.toolDesc : nil) : snapshot.last?.toolDetail }
    var project: String? { useHook ? hook!.project : snapshot.last?.project }

    var sessionPct: Double { snapshot.sessionPct }
    var weekPct: Double { snapshot.weekPct }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        if d >= 1e9 { return "\(f.string(from: NSNumber(value: d / 1e9))!) bi" }
        if d >= 1e6 { return "\(f.string(from: NSNumber(value: d / 1e6))!) mi" }
        if d >= 1e3 { f.maximumFractionDigits = 0; f.minimumFractionDigits = 0; return "\(f.string(from: NSNumber(value: d / 1e3))!) mil" }
        return "\(n)"
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(max(0, now.timeIntervalSince(d)))
        if s < 60 { return "há \(s) s" }
        if s < 3600 { return "há \(s / 60) min" }
        return "às \(time(d))"
    }

    static func weekdayTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d).replacingOccurrences(of: ".", with: "")
    }

    // "20:59" -> próxima vez que o relógio marcar 20:59.
    static func nextTime(_ hhmm: String, after now: Date = Date()) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.nextDate(after: now, matching: DateComponents(hour: parts[0], minute: parts[1]),
                                         matchingPolicy: .nextTime)
    }
}

// Paleta "e-ink", fixa pra parecer o Kindle independente do tema do Mac.
private let ink = Color(red: 0.16, green: 0.16, blue: 0.16)
private let paper = Color(red: 0.91, green: 0.90, blue: 0.87)
private let faded = Color(red: 0.55, green: 0.55, blue: 0.53)

struct Caption: View {
    let text: String
    var color: Color = faded
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(color)
    }
}

struct Dial: View {
    let pct: Double
    let label: String
    let footnote: String
    private let segments = 24

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                ForEach(0..<segments, id: \.self) { i in
                    let on = Double(i) < pct * Double(segments)
                    Capsule()
                        .fill(on ? ink : ink.opacity(0.15))
                        .frame(width: 4, height: 9)
                        .offset(y: -34)
                        .rotationEffect(.degrees(Double(i) / Double(segments) * 360))
                }
                VStack(spacing: 0) {
                    Text("\(Int((pct * 100).rounded()))%").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Caption(text: label)
                }
            }
            .frame(width: 82, height: 82)
            Text(footnote).font(.system(size: 9, design: .monospaced)).foregroundStyle(faded)
        }
    }
}

struct Panel: View {
    @ObservedObject var m: Monitor

    var body: some View {
        let s = m.snapshot
        let state = m.state
        HStack(spacing: 0) {
            // Lado escuro: Claudinho + relógio
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "Claude Code", color: paper.opacity(0.7))
                Spacer(minLength: 0)
                ChefView(ticker: m.ticker, state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text("✱ \(state.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(paper)
                    Text(state.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(paper.opacity(0.5))
                }
                Spacer(minLength: 0)
                TimelineView(.everyMinute) { ctx in
                    Text(Fmt.time(ctx.date)).font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(paper)
                }
            }
            .padding(16)
            .frame(width: 175, alignment: .leading)
            .background(ink)

            // Lado claro: atividade + uso
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "No fogo agora")
                HStack(spacing: 6) {
                    Text("▸ \(m.toolName ?? (state == .thinking ? "pensando…" : "nada no fogo"))").font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(m.toolDetail ?? "").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(paper)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ink, in: RoundedRectangle(cornerRadius: 3))
                if let p = m.project {
                    Text("em \(p)").font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
                }

                HStack {
                    Spacer()
                    Dial(pct: m.sessionPct, label: "sessão",
                         footnote: s.sessionResetsAt.map { "renova às \(Fmt.time($0))" } ?? "sem sessão ativa")
                    Spacer()
                    Dial(pct: m.weekPct, label: "semana",
                         footnote: s.weekResetsAt.map { "renova \(Fmt.weekdayTime($0))" } ?? "")
                    Spacer()
                }
                .padding(.vertical, 4)

                Rectangle().fill(ink).frame(height: 1)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Caption(text: "Tokens hoje")
                        Text(Fmt.tokens(s.todayTokens)).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    }
                    Spacer()
                    Text("média 7d: \(Fmt.tokens(s.avg7dTokens))/dia\n" + (s.calibrated
                         ? "● ao vivo · \(Fmt.ago(m.config.calibration!.at))"
                         : "% estimado pelos logs"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).multilineTextAlignment(.trailing)
                        .help(s.calibrated ? "última leitura real via \(m.config.calibration!.source ?? "/usage")" : "sem leitura real nesta janela")
                }
            }
            .padding(16)
            .frame(width: 300)
            .background(paper)
        }
        .frame(height: 280)
        .overlay {
            if m.calibrating { CalibrationForm(m: m) }
        }
        .overlay(alignment: .topTrailing) {
            if !m.isDemo { menu }
        }
    }

    private var menu: some View {
        Menu {
            Button(m.probing ? "Lendo /usage…" : "Recalibrar agora") { m.probeNow() }.disabled(m.probing)
            Button("Calibrar à mão…") { m.calibrating = true }
            Button("Editar config.json") { NSWorkspace.shared.open(Config.url) }
            Button("Atualizar agora") { m.refresh() }
            Divider()
            Button("Sair do Claudinho") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(faded)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(10)
    }
}


struct CalibrationForm: View {
    @ObservedObject var m: Monitor
    @StateObject private var draft = Draft()

    final class Draft: ObservableObject {
        @Published var session = ""
        @Published var week = ""
        @Published var reset = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(text: "Calibrar com /usage")
            Text("Rode /usage no Claude Code e copie os números daqui.")
                .font(.system(size: 11)).foregroundStyle(faded)
            field("Sessão atual (%)", $draft.session)
            field("Sessão renova às (HH:mm)", $draft.reset)
            field("Semana atual (%)", $draft.week)
            HStack {
                Button("Cancelar") { m.calibrating = false }
                Spacer()
                Button("Salvar") {
                    guard let sp = Double(draft.session.replacingOccurrences(of: ",", with: ".")),
                          let wp = Double(draft.week.replacingOccurrences(of: ",", with: ".")),
                          let r = Fmt.nextTime(draft.reset) else { return }
                    m.calibrate(sessionPct: sp / 100, weekPct: wp / 100, sessionResetsAt: r, source: "manual")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
        .foregroundStyle(ink)
        .onAppear {
            draft.session = "\(Int((m.sessionPct * 100).rounded()))"
            draft.week = "\(Int((m.weekPct * 100).rounded()))"
            draft.reset = m.snapshot.sessionResetsAt.map(Fmt.time) ?? ""
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(label).font(.system(size: 12, design: .monospaced))
            Spacer()
            TextField("", text: text).textFieldStyle(.roundedBorder).frame(width: 80)
        }
    }
}

struct ChefView: View {
    @ObservedObject var ticker: Ticker
    let state: ChefState
    var body: some View {
        Image(nsImage: Sprites.image(state, frame: ticker.frame, pixel: 5, color: NSColor(paper), template: false))
            .interpolation(.none)
    }
}
