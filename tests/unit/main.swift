// Testes do que já funciona. Rodam com ./tests/run.sh, sem tocar em ~/.claudinho nem em
// ~/.claude: CLAUDINHO_DIR e CLAUDINHO_PROJECTS apontam pra pastas temporárias.
import Foundation
import SwiftUI

var failures = 0, passed = 0
func check(_ cond: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if cond { passed += 1 } else { failures += 1; print("  FALHOU  \(what)  (\(file):\(line))") }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
func section(_ name: String) { print("• \(name)") }

let env = ProcessInfo.processInfo.environment
let dataDir = URL(fileURLWithPath: env["CLAUDINHO_DIR"]!)
let projects = URL(fileURLWithPath: env["CLAUDINHO_PROJECTS"]!)
let fixtures = URL(fileURLWithPath: env["CLAUDINHO_FIXTURES"]!)
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

// MARK: sprites
section("sprites")
let all: [ChefState] = [.thinking, .chopping, .frying, .seasoning, .plating, .waiting, .asking, .resting]
for s in all {
    for f in 0..<2 {
        let g = Sprites.grid(s, frame: f)
        check(g.count == Sprites.height && g.allSatisfy { $0.count == Sprites.width }, "\(s) quadro \(f) tem 27x16")
        check(g.joined().contains(true), "\(s) quadro \(f) não está vazio")
    }
    check(Sprites.grid(s, frame: 0) != Sprites.grid(s, frame: 1) || !s.animated, "\(s) anima entre os quadros")
    check(!s.title.isEmpty && !s.subtitle.isEmpty, "\(s) tem título e subtítulo")
}
check(Sprites.grid(.asking, frame: 0) != Sprites.grid(.waiting, frame: 0), "pedindo permissão desenha diferente de esperando")
check(!ChefState.resting.animated && !ChefState.waiting.animated && ChefState.frying.animated, "só anima quando tem trabalho")
let img = Sprites.image(.frying, frame: 0, pixel: 1, color: .black, template: true)
check(img.size == NSSize(width: 27, height: 16) && img.isTemplate, "ícone da barra é template 27x16")

// MARK: /usage
section("leitura do /usage")
let tela = try! String(contentsOf: fixtures.appendingPathComponent("usage_tela.txt"), encoding: .utf8)
if let r = UsageProbe.parse(tela) {
    check(near(r.sessionPct, 0.09), "sessão = 9% (veio \(r.sessionPct))")
    check(near(r.weekPct, 0.12), "semana = 12% (veio \(r.weekPct))")
    let h = Calendar.current.dateComponents([.hour, .minute], from: r.sessionResetsAt)
    check(h.hour == 1 && h.minute == 59, "sessão renova 1:59am")
} else { check(false, "parse da tela real do /usage") }
let semSessao = "Current session\n 0% used\n Current week (all models)\n 5% used\n"
check(UsageProbe.parse(semSessao).map { near($0.weekPct, 0.05) && near($0.sessionPct, 0) } == true, "sem 'Resets' ainda lê a semana")
check(UsageProbe.parse("lixo sem números") == nil, "tela sem números não vira leitura")
for (t, hh, mm) in [("9pm", 21, 0), ("8:59pm", 20, 59), ("12am", 0, 0), ("12pm", 12, 0), ("1:59 am", 1, 59)] {
    let d = UsageProbe.nextClockTime(t)
    let c = d.map { Calendar.current.dateComponents([.hour, .minute], from: $0) }
    check(c?.hour == hh && c?.minute == mm && d! > Date(), "horário \(t) -> \(hh):\(mm) no futuro")
}
check(UsageProbe.nextClockTime("25pm") == nil, "horário inválido é recusado")

// MARK: históricos
section("históricos .jsonl")
let now = Date()
func line(_ obj: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)! }
func assistant(_ id: String, _ t: Date, model: String = "claude-opus-5-5", usage: [String: Any], content: [[String: Any]], stop: String) -> String {
    line(["type": "assistant", "timestamp": iso.string(from: t), "requestId": "r-\(id)", "cwd": "/x/meu-projeto",
          "message": ["id": id, "model": model, "usage": usage, "content": content, "stop_reason": stop]])
}
let u1: [String: Any] = ["input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000,
                         "cache_creation_input_tokens": 200, "cache_creation": ["ephemeral_1h_input_tokens": 200]]
let t1 = now.addingTimeInterval(-120), t2 = now.addingTimeInterval(-60)
let jsonl = [
    line(["type": "user", "timestamp": iso.string(from: t1.addingTimeInterval(-5)), "cwd": "/x/meu-projeto", "message": ["content": "oi"]]),
    // mesma resposta em duas linhas (thinking + tool_use) com o mesmo usage: conta uma vez só
    assistant("m1", t1, usage: u1, content: [["type": "thinking"]], stop: "tool_use"),
    assistant("m1", t1, usage: u1, content: [["type": "tool_use", "name": "Bash", "input": ["command": "ls", "description": "Lista"]]], stop: "tool_use"),
    assistant("m2", t2, model: "claude-haiku-5-5", usage: ["input_tokens": 1000, "output_tokens": 0], content: [["type": "text"]], stop: "end_turn"),
].joined(separator: "\n") + "\n"
let projDir = projects.appendingPathComponent("-x-meu-projeto")
try! FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
let file = projDir.appendingPathComponent("s.jsonl")
try! jsonl.write(to: file, atomically: true, encoding: .utf8)

var cfg = Config()
cfg.calibration = nil
cfg.sessionLimitUnits = 10_000
cfg.weeklyLimitUnits = 100_000
let reader = UsageReader()
var snap = reader.refresh(config: cfg, now: now)
check(snap.todayTokens == 2310 || !Calendar.current.isDateInToday(t1), "tokens hoje = 2310 sem duplicar (veio \(snap.todayTokens))")
// unidades: m1 = 10 + 5*100 + 2*200 + 0.1*1000 = 1010 ; m2 (haiku 0.2) = 1000*0.2 = 200
let units = reader.units(from: now.addingTimeInterval(-3600), to: now)
check(near(units, 1210), "unidades ponderadas = 1210 (veio \(units))")
check(snap.last?.kind == .assistantDone, "última atividade = terminou")
check(snap.last?.project == "meu-projeto", "projeto vem do cwd")
check(near(snap.sessionPct, 0.121, 1e-9), "sem âncora, sessão = unidades/limite (veio \(snap.sessionPct))")

// leitura incremental: só a linha nova entra
let h = try! FileHandle(forWritingTo: file); h.seekToEndOfFile()
h.write((assistant("m3", now, usage: ["input_tokens": 0, "output_tokens": 0], content: [["type": "tool_use", "name": "Edit", "input": ["file_path": "/a/b/App.swift"]]], stop: "tool_use") + "\n").data(using: .utf8)!)
try! h.close()
snap = reader.refresh(config: cfg, now: now.addingTimeInterval(1))
check(snap.last?.kind == .assistantTool && snap.last?.toolName == "Edit" && snap.last?.toolDetail == "App.swift", "linha nova lida: Edit em App.swift")
check(near(reader.units(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(1)), 1210), "linhas antigas não contam de novo")

// âncora: % real + o que veio depois
cfg.calibration = Calibration(at: t1.addingTimeInterval(30), sessionPct: 0.40, sessionResetsAt: now.addingTimeInterval(3600), weekPct: 0.20, source: "/usage")
snap = reader.refresh(config: cfg, now: now.addingTimeInterval(2))
check(near(snap.sessionPct, 0.40 + 200.0 / 10_000), "com âncora, sessão = 40% + depois (veio \(snap.sessionPct))")
check(snap.calibrated && snap.sessionResetsAt == cfg.calibration!.sessionResetsAt, "usa o horário de renovação da âncora")

// MARK: config
section("config")
var wc = Config()
wc.weekResetsAt = iso.date(from: "2026-10-24T12:59:00.000Z")!
let w = wc.weekWindow(at: iso.date(from: "2026-10-30T10:00:00.000Z")!)
check(w.end == iso.date(from: "2026-10-31T12:59:00.000Z")! && w.duration == 7 * 86400, "semana segue o ciclo de 7 dias")
let old = try! JSONDecoder().decode(Config.self, from: #"{"sessionLimitUnits":1,"weeklyLimitUnits":2,"weekResetsAt":0}"#.data(using: .utf8)!)
check(old.liveProbeSeconds == nil && old.calibration == nil, "config antigo, sem campos novos, ainda carrega")

// MARK: hooks
section("arquivos dos hooks")
let t = now.timeIntervalSince1970
let state: [String: Any] = ["sessions": [
    "a": ["status": "working", "tool_running": true, "tool_name": "Bash", "tool_desc": "ls", "project": "p1", "last_event": t - 10],
    "b": ["status": "asking", "tool_running": false, "project": "p2", "last_event": t - 20],
    "c": ["status": "done", "project": "p3", "last_event": t - 1],
    "d": ["status": "working", "project": "velha", "last_event": t - 7200],
    "e": ["status": "closed", "project": "fechada", "last_event": t],
]]
try! JSONSerialization.data(withJSONObject: state).write(to: dataDir.appendingPathComponent("state.json"))
let sessions = HookFiles.sessions()
check(sessions.count == 5, "lê todas as sessões")
check(HookFiles.mostUrgent(sessions)?.project == "p2", "a mais urgente é a que pede permissão")
check(HookFiles.mostUrgent(sessions.filter { $0.status != "asking" })?.project == "p1", "depois, a que está trabalhando")
check(HookFiles.mostUrgent(sessions.filter { $0.project == "velha" || $0.project == "fechada" }) == nil, "sessão velha ou fechada não conta")
let rl = #"{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1793000000},"seven_day":{"used_percentage":12,"resets_at":"2026-10-24T12:59:00Z"}},"saved_at":1792697777.8}"#
try! rl.write(to: dataDir.appendingPathComponent("statusline.json"), atomically: true, encoding: .utf8)
let r = HookFiles.rateLimits()
check(r.map { near($0.sessionPct, 0.235) && near($0.weekPct, 0.12) } == true, "statusLine: 23,5% e 12%")
check(r?.sessionResetsAt == Date(timeIntervalSince1970: 1793000000), "resets_at em epoch")
check(r?.weekResetsAt == ISO8601DateFormatter().date(from: "2026-10-24T12:59:00Z"), "resets_at em texto ISO")

// MARK: estado do Monitor
section("estado do chef")
func monitorState(last: LastEvent?, hook: HookSession? = nil) -> ChefState {
    var s = Snapshot(); s.last = last
    return Monitor(demo: nil, snapshot: s, hook: hook).state
}
func ev(_ k: LastEvent.Kind, _ ago: TimeInterval, tool: String? = nil) -> LastEvent {
    LastEvent(kind: k, ts: Date().addingTimeInterval(-ago), toolName: tool, toolDetail: nil, project: nil)
}
check(monitorState(last: nil) == .resting, "sem nada = descansando")
check(monitorState(last: ev(.user, 5)) == .thinking, "mensagem sua = pensando")
check(monitorState(last: ev(.assistantTool, 5, tool: "Bash")) == .frying, "Bash = frigideira")
check(monitorState(last: ev(.assistantTool, 5, tool: "Edit")) == .chopping, "Edit = cebola")
check(monitorState(last: ev(.assistantTool, 5, tool: "Grep")) == .seasoning, "Grep = tempero")
check(monitorState(last: ev(.assistantTool, 5, tool: "AskUserQuestion")) == .waiting, "pergunta = esperando")
check(monitorState(last: ev(.assistantDone, 10)) == .plating, "acabou de terminar = prato pronto")
check(monitorState(last: ev(.assistantDone, 200)) == .waiting, "terminou faz tempo = esperando")
check(monitorState(last: ev(.assistantTool, 20 * 60, tool: "Bash")) == .resting, "parado há 20 min = descansando")
let asking = HookSession(status: "asking", toolRunning: false, toolName: nil, toolDesc: nil, project: "p", lastEvent: Date())
check(monitorState(last: ev(.assistantTool, 30, tool: "Bash"), hook: asking) == .asking, "hook recente manda: pedindo permissão")
let oldHook = HookSession(status: "asking", toolRunning: false, toolName: nil, toolDesc: nil, project: "p", lastEvent: Date().addingTimeInterval(-600))
check(monitorState(last: ev(.user, 5), hook: oldHook) == .thinking, "hook mais velho que os logs é ignorado")

// MARK: calibração
section("calibração")
func calibrateAndWait(_ m: Monitor, _ s: Double, _ w: Double, reset: Date, source: String, at: Date = Date()) {
    m.calibrate(sessionPct: s, weekPct: w, sessionResetsAt: reset, at: at, source: source)
    let end = Date().addingTimeInterval(3)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
let m = Monitor(demo: nil, snapshot: Snapshot())
let reset = Date().addingTimeInterval(3 * 3600)
var base = Config(); base.calibration = Calibration(at: Date().addingTimeInterval(-60), sessionPct: 0.20, sessionResetsAt: reset, weekPct: 0.10, source: "/usage")
base.save()
calibrateAndWait(m, 0.05, 0.08, reset: reset, source: "statusLine")
check(near(Config.load().calibration!.sessionPct, 0.20), "statusLine que anda pra trás é ignorada")
calibrateAndWait(m, 0.25, 0.11, reset: reset, source: "/usage")
check(near(Config.load().calibration!.sessionPct, 0.25), "leitura maior é aceita")
calibrateAndWait(m, 0.02, 0.11, reset: reset, source: "manual")
check(near(Config.load().calibration!.sessionPct, 0.02), "manual pode corrigir pra baixo")
calibrateAndWait(m, 0.01, 0.01, reset: Date().addingTimeInterval(5 * 3600), source: "/usage")
check(near(Config.load().calibration!.sessionPct, 0.01), "janela nova começa do zero")

// MARK: painel
section("painel")
MainActor.assumeIsolated {
    var s = Snapshot(); s.todayTokens = 147_700_000; s.sessionPct = 0.13; s.weekPct = 0.31
    let cg = ImageRenderer(content: Panel(m: Monitor(demo: .frying, snapshot: s))).cgImage
    check(cg.map { $0.width == 475 && $0.height == 280 } == true, "painel renderiza em 475x280 (veio \(cg.map { "\($0.width)x\($0.height)" } ?? "nada"))")
}
check(Fmt.tokens(147_700_000) == "147,7 mi" && Fmt.tokens(2_400_000_000) == "2,4 bi" && Fmt.tokens(850_000) == "850 mil", "formato dos tokens")
check(Fmt.ago(Date().addingTimeInterval(-12)) == "há 12 s" && Fmt.ago(Date().addingTimeInterval(-300)) == "há 5 min", "formato do 'há X'")

// MARK: widget
section("widget")
// datas em segundos inteiros: frações de segundo podem não sobreviver ao JSON
func whole(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded()) }
var ws = WidgetSnapshot.placeholder
ws.updatedAt = whole(ws.updatedAt)
ws.sessionResetsAt = ws.sessionResetsAt.map(whole)
ws.weekResetsAt = ws.weekResetsAt.map(whole)
ws.liveAt = ws.liveAt.map(whole)
ws.save()
check(WidgetSnapshot.url.path.hasPrefix(dataDir.path), "widget.json fica na pasta do Claudinho")
check(WidgetSnapshot.load() == ws, "widget.json vai e volta igual")
var ws2 = ws; ws2.updatedAt = ws.updatedAt.addingTimeInterval(40)
check(!ws2.looksDifferent(from: ws), "só o horário mudou: não recarrega o widget")
ws2.sessionPct += 0.011
check(ws2.looksDifferent(from: ws), "% mudou: recarrega")
ws2 = ws; ws2.state = .waiting
check(ws2.looksDifferent(from: ws), "estado mudou: recarrega")
var stale = ws; stale.updatedAt = Date().addingTimeInterval(-20 * 60)
check(stale.current().state == .resting && stale.current().toolName == nil, "app parado há 20 min: widget mostra descansando")
var expired = ws; expired.sessionResetsAt = Date().addingTimeInterval(-60)
check(expired.current().sessionPct == 0 && expired.current().sessionResetsAt == nil, "janela que já renovou zera a sessão")
check(ws.current().state == ws.state, "snapshot recente fica como está")
let fromMonitor = Monitor(demo: .frying, snapshot: { var s = Snapshot(); s.sessionPct = 0.42; s.weekPct = 0.2; return s }()).widgetSnapshot
check(fromMonitor.state == .frying && near(fromMonitor.sessionPct, 0.42), "Monitor monta o snapshot do widget")
MainActor.assumeIsolated {
    let e = Entry(date: Date(), snap: .placeholder, missing: false)
    @MainActor func size(_ v: some View, _ w: CGFloat, _ h: CGFloat) -> Bool {
        ImageRenderer(content: v.frame(width: w, height: h)).cgImage.map { $0.width == Int(w) && $0.height == Int(h) } == true
    }
    // tamanho real deste macOS e o tamanho maior de outras telas: os dois têm que caber
    for (w, h) in [(158, 158), (170, 170)] { check(size(SmallView(s: e.snap), CGFloat(w), CGFloat(h)), "widget pequeno renderiza em \(w)x\(h)") }
    for (w, h) in [(345, 158), (364, 170)] { check(size(MediumView(s: e.snap), CGFloat(w), CGFloat(h)), "widget médio renderiza em \(w)x\(h)") }
    for (w, h) in [(345, 345), (364, 382)] { check(size(LargeView(s: e.snap), CGFloat(w), CGFloat(h)), "widget grande renderiza em \(w)x\(h)") }
    check(size(MissingView(), 170, 170), "widget sem app renderiza")
}

// MARK: Claudinho de mesa
section("Claudinho de mesa")
check(CardSize.allCases.map(\.rawValue) == ["pequeno", "medio", "grande"], "três tamanhos, com nomes estáveis no mesa.json")
check(CardSize.pequeno.size == CGSize(width: 158, height: 158) && CardSize.grande.size == CGSize(width: 345, height: 345), "tamanhos iguais aos widgets do macOS")
check(DeskPrefs.load() == DeskPrefs(), "sem mesa.json: desligado e sem posição")
var prefs = DeskPrefs(size: .medio, x: 100, y: 200)
prefs.save()
check(DeskPrefs.url.path.hasPrefix(dataDir.path) && DeskPrefs.load() == prefs, "mesa.json vai e volta igual")
let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
check(prefs.origin(for: .medio, screens: [screen]) == CGPoint(x: 100, y: 200), "posição salva que cabe na tela é mantida")
let fora = DeskPrefs(size: .grande, x: 2000, y: 100)
check(fora.origin(for: .grande, screens: [screen]) == CGPoint(x: 1440 - 345 - 140, y: 875 - 345 - 20), "posição fora da tela volta pro canto de cima à direita")
let segunda = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
check(fora.origin(for: .grande, screens: [screen, segunda]) == CGPoint(x: 2000, y: 100), "posição numa segunda tela é mantida")
check(DeskPrefs(size: .pequeno, x: 1400, y: 10).origin(for: .pequeno, screens: [screen]).x == 1440 - 158 - 140, "cartão cortado na borda não conta como dentro")
check(DeskPrefs().origin(for: .medio, screens: []) == .zero, "sem tela nenhuma não quebra")
check(Monitor(demo: nil, snapshot: Snapshot()).deskSize == nil, "Monitor de teste começa com a mesa desligada")
MainActor.assumeIsolated {
    @MainActor func pixels(_ v: some View, _ size: CGSize) -> Data? {
        ImageRenderer(content: v.frame(width: size.width, height: size.height)).cgImage?.dataProvider?.data as Data?
    }
    var cozinhando = WidgetSnapshot.placeholder; cozinhando.state = .frying
    for size in CardSize.allCases {
        let f0 = pixels(Card(size: size, s: cozinhando, frame: 0), size.size)
        let f1 = pixels(Card(size: size, s: cozinhando, frame: 1), size.size)
        check(f0 != nil && f1 != nil, "cartão \(size.rawValue) renderiza")
        check(f0 != f1, "cartão \(size.rawValue) anima: quadro 1 desenha diferente do 0")
    }
    let m = Monitor(demo: .frying, snapshot: Snapshot())
    let desk = ImageRenderer(content: DeskView(monitor: m, ticker: m.ticker, size: .medio)).cgImage
    check(desk.map { $0.width == 345 && $0.height == 158 } == true, "janela de mesa tem o tamanho do widget médio")
    let host = DraggableHostingView(rootView: Text("x"))
    check(host.mouseDownCanMoveWindow && host.acceptsFirstMouse(for: nil), "cartão da mesa arrasta já no primeiro clique")
}

// MARK: instância única
section("instância única")
check(Instance.decide(mine: 5, others: []) == .run, "sozinho: roda")
check(Instance.decide(mine: 9, others: [5]) == .replaceOthers, "versão nova fecha a cópia velha")
check(Instance.decide(mine: 5, others: [9]) == .quit, "cópia velha fecha sozinha")
check(Instance.decide(mine: 5, others: [5]) == .quit, "mesma versão aberta duas vezes: a segunda fecha")
check(Instance.decide(mine: 1792709897, others: [0]) == .replaceOthers, "cópia sem número de build (0.2) perde pra atual")
check(Instance.build(of: nil) == 0 && Instance.build(of: URL(fileURLWithPath: "/nao/existe.app")) == 0, "build de app que não existe é 0")

print("\n\(passed) ok, \(failures) falha(s)")
exit(failures == 0 ? 0 : 1)
