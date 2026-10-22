// Gera as imagens do README com dados fictícios: ./build.sh --preview
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/img")
let inkNS = NSColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
let paperColor = NSColor(red: 0.91, green: 0.90, blue: 0.87, alpha: 1)

func demoSnapshot(tool: String?, detail: String?) -> Snapshot {
    var s = Snapshot()
    s.todayTokens = 147_700_000
    s.avg7dTokens = 98_300_000
    s.sessionPct = 0.13
    s.sessionResetsAt = Calendar.current.date(bySettingHour: 20, minute: 59, second: 0, of: Date())
    s.weekPct = 0.31
    s.weekResetsAt = Calendar.current.date(bySettingHour: 14, minute: 59, second: 0, of: Date().addingTimeInterval(2 * 86400))
    s.calibrated = true
    s.last = LastEvent(kind: tool == nil ? .assistantDone : .assistantTool, ts: Date(), toolName: tool, toolDetail: detail, project: "claudinho-widget")
    return s
}

func writePNG(_ cg: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

@MainActor func panel(_ state: ChefState, tool: String?, detail: String?, name: String) {
    let m = Monitor(demo: state, snapshot: demoSnapshot(tool: tool, detail: detail))
    m.config.calibration = Calibration(at: Date().addingTimeInterval(-12), sessionPct: 0.13, sessionResetsAt: Date(), weekPct: 0.31, source: "statusLine")
    let r = ImageRenderer(content: Panel(m: m).environment(\.colorScheme, .light))
    r.scale = 2
    writePNG(r.cgImage!, out.appendingPathComponent("estados/\(name).png"))
}

func cgImage(_ img: NSImage, background: NSColor, pad: CGFloat) -> CGImage {
    let size = NSSize(width: img.size.width + 2 * pad, height: img.size.height + 2 * pad)
    let canvas = NSImage(size: size, flipped: false) { rect in
        background.setFill(); rect.fill()
        img.draw(at: NSPoint(x: pad, y: pad), from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    return canvas.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!
}

func gif(_ state: ChefState, _ name: String, delay: Double = 0.8) {
    let url = out.appendingPathComponent("sprites/\(name).gif")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in 0..<2 {
        let img = Sprites.image(state, frame: frame, pixel: 8, color: paperColor, template: false)
        CGImageDestinationAddImage(dest, cgImage(img, background: inkNS, pad: 16),
                                   [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
}

// Como o ícone aparece na barra de menu, ampliado 4x.
func menuBar() {
    let icon = Sprites.image(.frying, frame: 0, pixel: 4, color: .black, template: false)
    let text = NSAttributedString(string: "13%", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 52, weight: .regular)])
    let size = NSSize(width: icon.size.width + text.size().width + 72, height: 100)
    let img = NSImage(size: size, flipped: false) { rect in
        NSColor(white: 0.93, alpha: 1).setFill(); rect.fill()
        icon.draw(at: NSPoint(x: 24, y: (rect.height - icon.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        text.draw(at: NSPoint(x: 24 + icon.size.width + 24, y: (rect.height - text.size().height) / 2))
        return true
    }
    writePNG(img.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 1)])!,
             out.appendingPathComponent("barra.png"))
}

try? FileManager.default.createDirectory(at: out.appendingPathComponent("estados"), withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: out.appendingPathComponent("sprites"), withIntermediateDirectories: true)
MainActor.assumeIsolated {
    panel(.frying, tool: "Bash", detail: "Roda os testes do projeto", name: "trabalhando")
    panel(.waiting, tool: nil, detail: nil, name: "esperando")
    panel(.asking, tool: "Bash", detail: "rm -rf build/", name: "pedindo")
    panel(.resting, tool: nil, detail: nil, name: "descansando")
}
for (state, name) in [(ChefState.thinking, "sopa"), (.chopping, "cebola"), (.frying, "frigideira"), (.seasoning, "tempero"),
                      (.plating, "prato"), (.waiting, "esperando"), (.resting, "descansando")] {
    gif(state, name, delay: state == .resting ? 1.6 : 0.8)
}
menuBar()

// Os três tamanhos do widget, com os cantos arredondados do macOS.
@MainActor func widget(_ v: some View, _ w: CGFloat, _ h: CGFloat, _ name: String) {
    let r = ImageRenderer(content: v.frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(10).background(Color(white: 0.12)))
    r.scale = 2
    writePNG(r.cgImage!, out.appendingPathComponent("widget/\(name).png"))
}
try? FileManager.default.createDirectory(at: out.appendingPathComponent("widget"), withIntermediateDirectories: true)
MainActor.assumeIsolated {
    let e = Entry(date: Date(), snap: .placeholder, missing: false)
    var resting = WidgetSnapshot.placeholder; resting.state = .resting; resting.toolName = nil; resting.toolDetail = nil
    widget(SmallView(e: e), 158, 158, "pequeno")
    widget(MediumView(e: e), 345, 158, "medio")
    widget(LargeView(e: e), 345, 345, "grande")
    widget(SmallView(e: Entry(date: Date(), snap: resting, missing: false)), 170, 170, "pequeno-descansando")
}
print("imagens em \(out.path)")
