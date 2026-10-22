// O widget nativo (mesa e Central de Notificações). Lê ~/.claudinho/widget.json, que o app
// grava, e desenha os cartões de CardViews.swift. Sem animação: widget no macOS não roda timer.
import WidgetKit
import SwiftUI

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
    let missing: Bool       // o app nunca gravou nada (não está instalado ou nunca rodou)
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .placeholder, missing: false) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    // O app pede recarga quando algo muda. Isto aqui é só a rede de segurança.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> Entry {
        let s = WidgetSnapshot.load()
        Self.log(s == nil ? "não li \(WidgetSnapshot.url.path)" : "li o snapshot: \(s!.state) \(Int(s!.sessionPct * 100))%")
        if let s { return Entry(date: Date(), snap: s.current(), missing: false) }
        return Entry(date: Date(), snap: .placeholder, missing: true)
    }

    // Diagnóstico: a última leitura do widget fica em ~/.claudinho/widget.log.
    static func log(_ msg: String) {
        let url = WidgetSnapshot.url.deletingLastPathComponent().appendingPathComponent("widget.log")
        try? "\(Date()) \(msg)\n".write(to: url, atomically: true, encoding: .utf8)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let e: Entry
    var body: some View {
        Group {
            if e.missing { MissingView() }
            else {
                switch family {
                case .systemSmall: Card(size: .pequeno, s: e.snap)
                case .systemLarge: Card(size: .grande, s: e.snap)
                default: Card(size: .medio, s: e.snap)
                }
            }
        }
        .containerBackground(ink, for: .widget)
        .environment(\.colorScheme, .light)
    }
}

struct ClaudinhoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "claudinho", provider: Provider()) { WidgetView(e: $0) }
            .configurationDisplayName("Claudinho")
            .description("O que o Claude Code está cozinhando e quanto do seu limite já foi.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
            .contentMarginsDisabled()
    }
}

#if !PREVIEW
@main
struct ClaudinhoWidgets: WidgetBundle {
    var body: some Widget { ClaudinhoWidget() }
}
#endif
