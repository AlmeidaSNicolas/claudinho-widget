import AppKit
import SwiftUI
import Combine

// Ícone na barra de menu em AppKit puro (barato de redesenhar); o painel SwiftUI
// só existe enquanto está aberto e é descartado ao fechar, pra não ocupar memória.
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let monitor = Monitor()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var popover: NSPopover?
    private var bag: Set<AnyCancellable> = []
    private var lastDrawn = ""

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeft
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        monitor.ticker.$frame.merge(with: monitor.$snapshot.map { _ in 0 })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.redraw() }
            .store(in: &bag)
    }

    private func redraw() {
        let state = monitor.state
        let frame = state.animated ? monitor.ticker.frame : 0
        let pct = "\(Int((monitor.sessionPct * 100).rounded()))%"
        let key = "\(state)-\(frame % 6)-\(pct)"
        guard key != lastDrawn, let button = item.button else { return }
        lastDrawn = key
        button.image = Sprites.image(state, frame: frame, pixel: 1, color: .black, template: true)
        button.title = " " + pct
        button.toolTip = "Claudinho · \(state.title)"
    }

    @objc private func toggle() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        p.contentViewController = NSHostingController(rootView: Panel(m: monitor))
        monitor.panelOpen = true
        monitor.refresh()
        p.show(relativeTo: item.button!.bounds, of: item.button!, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover = p
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.panelOpen = false
        monitor.calibrating = false
        popover = nil
    }
}

#if !PREVIEW
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
    }
}
#endif
