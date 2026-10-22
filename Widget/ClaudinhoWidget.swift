// O widget de mesa / Central de Notificações. Lê ~/.claudinho/widget.json, que o app grava,
// e se desenha no mesmo estilo do painel. Sem animação: widget no macOS não roda timer.
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
        if let s = WidgetSnapshot.load() { return Entry(date: Date(), snap: s.current(), missing: false) }
        return Entry(date: Date(), snap: .placeholder, missing: true)
    }
}

// MARK: peças

struct Chef: View {
    let state: ChefState
    let pixel: CGFloat
    var body: some View {
        Image(nsImage: Sprites.image(state, frame: 0, pixel: pixel, color: NSColor(paper), template: false))
            .interpolation(.none)
    }
}

struct Pct: View {
    let value: Double
    let size: CGFloat
    let color: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(Int((value * 100).rounded()))").font(.system(size: size, weight: .bold, design: .rounded))
            Text("%").font(.system(size: size * 0.5, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
    }
}

struct Resets: View {
    let date: Date?
    var body: some View {
        if let date {
            (Text("renova em ") + Text(date, style: .relative))
        } else {
            Text("sem sessão ativa")
        }
    }
}

struct ToolBar: View {
    let s: WidgetSnapshot
    var body: some View {
        HStack(spacing: 5) {
            Text("▸ \(s.toolName ?? (s.state == .thinking ? "pensando…" : "nada no fogo"))")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Text(s.toolDetail ?? "").font(.system(size: 10, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(paper)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink, in: RoundedRectangle(cornerRadius: 3))
    }
}

struct ChefSide: View {
    let s: WidgetSnapshot
    let pixel: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(text: "Claude Code", color: paper.opacity(0.6))
            Spacer(minLength: 0)
            Chef(state: s.state, pixel: pixel)
            VStack(alignment: .leading, spacing: 1) {
                Text("✱ \(s.state.title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(paper).lineLimit(1)
                Text(s.state.subtitle).font(.system(size: 9, design: .monospaced)).foregroundStyle(paper.opacity(0.5)).lineLimit(1)
            }
        }
    }
}

// MARK: tamanhos

struct SmallView: View {
    let e: Entry
    var body: some View {
        let s = e.snap
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Caption(text: "Sessão", color: paper.opacity(0.6))
                Spacer()
                Chef(state: s.state, pixel: 1.5)
            }
            Pct(value: s.sessionPct, size: 40, color: paper)
            Resets(date: s.sessionResetsAt).font(.system(size: 10, design: .monospaced)).foregroundStyle(paper.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 4)
            Text("✱ \(s.state.title)").font(.system(size: 13, weight: .semibold)).foregroundStyle(paper).lineLimit(1)
            Text("semana \(Int((s.weekPct * 100).rounded()))%")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(paper.opacity(0.55)).lineLimit(1)
            Text("\(Fmt.tokens(s.todayTokens)) hoje")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(paper.opacity(0.55)).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ink)
    }
}

struct MediumView: View {
    let e: Entry
    var body: some View {
        let s = e.snap
        HStack(spacing: 0) {
            ChefSide(s: s, pixel: 3)
                .padding(14)
                .frame(width: 128, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(ink)
            VStack(alignment: .leading, spacing: 6) {
                ToolBar(s: s)
                HStack(spacing: 10) {
                    Dial(pct: s.sessionPct, label: "sessão", footnote: "", size: 62)
                    Dial(pct: s.weekPct, label: "semana", footnote: "", size: 62)
                }
                .frame(maxWidth: .infinity)
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.tokens(s.todayTokens)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Text("hoje").font(.system(size: 9, design: .monospaced)).foregroundStyle(faded)
                    Spacer()
                    if let r = s.sessionResetsAt {
                        (Text("↻ ") + Text(r, style: .relative)).font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(paper)
        }
    }
}

struct LargeView: View {
    let e: Entry
    var body: some View {
        let s = e.snap
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                ChefSide(s: s, pixel: 4)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Caption(text: "Sessão", color: paper.opacity(0.6))
                    Pct(value: s.sessionPct, size: 52, color: paper)
                }
            }
            .padding(18)
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .background(ink)
            VStack(alignment: .leading, spacing: 10) {
                Caption(text: "No fogo agora")
                ToolBar(s: s)
                if let p = s.project {
                    Text("em \(p)").font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
                }
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Dial(pct: s.sessionPct, label: "sessão", footnote: "", size: 76)
                        Resets(date: s.sessionResetsAt).font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Dial(pct: s.weekPct, label: "semana", footnote: "", size: 76)
                        Resets(date: s.weekResetsAt).font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
                    }
                    Spacer()
                }
                Rectangle().fill(ink).frame(height: 1)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Caption(text: "Tokens hoje")
                        Text(Fmt.tokens(s.todayTokens)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    }
                    Spacer()
                    Text("média 7d: \(Fmt.tokens(s.avg7dTokens))/dia\n" + (s.liveAt.map { "● ao vivo · \(Fmt.time($0))" } ?? "estimado"))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).multilineTextAlignment(.trailing)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(paper)
        }
    }
}

struct MissingView: View {
    var body: some View {
        VStack(spacing: 8) {
            Chef(state: .resting, pixel: 2)
            Text("Abra o Claudinho").font(.system(size: 12, weight: .semibold)).foregroundStyle(paper)
            Text("o widget lê o que o app da barra de menu grava")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(paper.opacity(0.55)).multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ink)
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
                case .systemSmall: SmallView(e: e)
                case .systemLarge: LargeView(e: e)
                default: MediumView(e: e)
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
