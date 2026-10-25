import SwiftUI
import AppKit
import WidgetKit

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
    @Published var deskSize: CardSize?          // Claudinho de mesa ligado e em que tamanho

    @Published var probing = false
    var panelOpen = false

    private let reader = UsageReader()
    private let queue = DispatchQueue(label: "claudinho.reader")
    private var timers: [Timer] = []
    private var lastProbe = Date.distantPast
    private var demoState: ChefState?
    private var ignoredStatusLineAt: Date?
    private var watcher: DispatchSourceFileSystemObject?
    private var sentToWidget: WidgetSnapshot?
    private var widgetReloadedAt = Date.distantPast
    private var reloadPending = false
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
                self.publishToWidget()
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
            // O limite só é medido com leituras do /usage: a statusLine pode repetir um % velho e a
            // manual é palpite. Precisa de folga (15 min e 5 pontos na sessão) pra não medir ruído.
            if source == "/usage" {
                cfg.record(sessionPct: sessionPct, sessionEnd: sessionResetsAt, weekPct: weekPct, at: at)
                let units = { (a: Date, b: Date) in self.reader.units(from: a, to: b) }
                if let est = Config.estimateLimit(cfg.sessionReadings ?? [], minSpan: 15 * 60, minDelta: 0.05, units: units) {
                    cfg.sessionLimitUnits = Config.refine(cfg.sessionLimitUnits, toward: est)
                }
                if let est = Config.estimateLimit(cfg.weekReadings ?? [], minSpan: 3600, minDelta: 0.03, units: units) {
                    cfg.weeklyLimitUnits = Config.refine(cfg.weeklyLimitUnits, toward: est)
                }
            }
            if let weekResetsAt { cfg.weekResetsAt = weekResetsAt }
            cfg.calibration = Calibration(at: at, sessionPct: sessionPct, sessionResetsAt: sessionResetsAt,
                                          weekPct: weekPct, source: source)
            cfg.save()
            let snap = self.reader.refresh(config: cfg)
            DispatchQueue.main.async { self.config = cfg; self.snapshot = snap; self.calibrating = false; self.publishToWidget() }
        }
    }

    var widgetSnapshot: WidgetSnapshot {
        WidgetSnapshot(updatedAt: Date(), state: state, sessionPct: sessionPct, sessionResetsAt: snapshot.sessionResetsAt,
                       weekPct: weekPct, weekResetsAt: snapshot.weekResetsAt, todayTokens: snapshot.todayTokens,
                       avg7dTokens: snapshot.avg7dTokens, toolName: toolName, toolDetail: toolDetail, project: project,
                       liveAt: snapshot.calibrated ? config.calibration?.at : nil)
    }

    // O macOS limita quantas vezes por dia um widget pode recarregar. Por isso só pede quando o
    // desenho muda: troca de estado na hora, o resto no máximo a cada 30 s. O arquivo em si é
    // regravado a cada minuto pro widget saber que o app está vivo.
    private func publishToWidget() {
        guard timersStarted else { return }
        let next = widgetSnapshot
        let now = Date()
        let changed = sentToWidget.map { next.looksDifferent(from: $0) } ?? true
        let stateChanged = sentToWidget?.state != next.state
        let alive = now.timeIntervalSince(sentToWidget?.updatedAt ?? .distantPast) > 60
        if changed { reloadPending = true }
        guard changed || alive || reloadPending else { return }
        if changed || alive { next.save(); sentToWidget = next }
        if reloadPending && (stateChanged || now.timeIntervalSince(widgetReloadedAt) > 30) {
            reloadPending = false
            widgetReloadedAt = now
            WidgetCenter.shared.reloadTimelines(ofKind: "claudinho")
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
        if ChefState.isOutOfGas(sessionPct: sessionPct, weekPct: weekPct) { return .outOfGas }
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
            Menu("Claudinho de mesa") { DeskMenu(monitor: m) }
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
