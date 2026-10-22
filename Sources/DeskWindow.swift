// O Claudinho de mesa: os mesmos cartões do widget nativo, numa janela sem borda presa no
// fundo da mesa. Roda dentro do app, então é ao vivo e anima, coisa que widget não faz.
import AppKit
import SwiftUI
import Combine

// Tamanho e posição ficam em ~/.claudinho/mesa.json, separados do config.json, que a
// calibração regrava de outra fila.
struct DeskPrefs: Codable, Equatable {
    var size: CardSize?
    var x: Double?
    var y: Double?

    static var url: URL { HookFiles.dir.appendingPathComponent("mesa.json") }

    static func load() -> DeskPrefs {
        guard let data = try? Data(contentsOf: url) else { return DeskPrefs() }
        return (try? JSONDecoder().decode(DeskPrefs.self, from: data)) ?? DeskPrefs()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    // A posição salva, se o cartão ainda cabe numa das telas; senão o canto de cima à direita
    // da primeira, longe dos ícones da mesa. (Monitor desligado, resolução trocada…)
    func origin(for card: CardSize, screens: [CGRect]) -> CGPoint {
        let size = card.size
        if let x, let y {
            let rect = CGRect(origin: CGPoint(x: x, y: y), size: size)
            if screens.contains(where: { $0.contains(rect) }) { return rect.origin }
        }
        guard let vf = screens.first else { return .zero }
        return CGPoint(x: vf.maxX - size.width - 140, y: vf.maxY - size.height - 20)
    }
}

struct DeskView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var ticker: Ticker
    let size: CardSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        Card(size: size, s: monitor.widgetSnapshot, frame: monitor.state.animated ? ticker.frame : 0)
            .frame(width: size.size.width, height: size.size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08)))
            .environment(\.colorScheme, .light)
            .contextMenu { DeskMenu(monitor: monitor) }
    }
}

// Escolher o tamanho ou esconder: no botão direito do cartão e no menu ⋯ do painel.
struct DeskMenu: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        ForEach(CardSize.allCases, id: \.self) { size in
            Button((monitor.deskSize == size ? "✓ " : "") + size.title) { monitor.deskSize = size }
        }
        if monitor.deskSize != nil {
            Divider()
            Button("Esconder da mesa") { monitor.deskSize = nil }
        }
    }
}

// Arrastar o cartão por qualquer ponto move a janela. Só "pode mover pelo fundo" não basta:
// o SwiftUI fica com o clique e a janela não sai do lugar. E como o app nunca fica ativo,
// sem acceptsFirstMouse o primeiro clique só serviria pra ativar a janela.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class DeskController: NSObject, NSWindowDelegate {
    private let monitor: Monitor
    private var panel: NSPanel?
    private var prefs = DeskPrefs.load()
    private var bag: Set<AnyCancellable> = []

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        monitor.deskSize = prefs.size
        monitor.$deskSize.removeDuplicates().sink { [weak self] size in self?.apply(size) }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.apply(self?.prefs.size) }
    }

    private func apply(_ size: CardSize?) {
        prefs.size = size
        prefs.save()
        guard let size else { panel?.orderOut(nil); panel = nil; return }
        let p = panel ?? makePanel()
        p.contentView = DraggableHostingView(rootView: DeskView(monitor: monitor, ticker: monitor.ticker, size: size))
        let origin = prefs.origin(for: size, screens: NSScreen.screens.map(\.visibleFrame))
        p.setFrame(CGRect(origin: origin, size: size.size), display: true)
        p.orderFront(nil)
        p.invalidateShadow()
        panel = p
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Logo acima dos ícones da mesa e abaixo de qualquer janela, como os widgets da Apple.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        return p
    }

    func windowDidMove(_ notification: Notification) {
        guard let o = panel?.frame.origin else { return }
        prefs.x = o.x
        prefs.y = o.y
        prefs.save()
    }
}
