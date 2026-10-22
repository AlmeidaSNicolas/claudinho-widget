// Gera o ícone do app a partir do sprite: ./build.sh --icon
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
let ink = NSColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
let paper = NSColor(red: 0.91, green: 0.90, blue: 0.87, alpha: 1)
let clay = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)   // corpo do Claudinho

func icon(_ side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .none

    // Grade de ícone do macOS: 824/1024 de área útil, cantos de ~185/1024.
    let inset = side * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: side * 185 / 1024, yRadius: side * 185 / 1024)
    ink.setFill(); shape.fill()
    paper.withAlphaComponent(0.25).setStroke(); shape.lineWidth = max(1, side / 256); shape.stroke()

    // Bancada de papel embaixo, como o lado claro do painel.
    shape.addClip()
    paper.setFill()
    NSRect(x: 0, y: 0, width: side, height: inset + body.height * 0.2).fill()

    // Pequeno demais pra cena inteira: só o Claudinho, maior.
    let full = Sprites.grid(.thinking, frame: 0)
    let g = side < 128 ? full.map { Array($0[0..<12]) } : full
    let cols = CGFloat(g[0].count), rows = CGFloat(g.count)
    let px = max(1, floor(min(body.width * 0.84 / cols, body.height * 0.66 / rows)))
    let w = px * cols, h = px * rows
    let x0 = round(body.midX - w / 2), y0 = round(inset + body.height * 0.2)   // pés na bancada
    NSGraphicsContext.current?.shouldAntialias = false   // sem fresta entre os pixels
    for (y, row) in g.enumerated() {
        for (x, on) in row.enumerated() where on {
            (x < 12 && y >= 5 ? clay : paper).setFill()
            NSRect(x: x0 + CGFloat(x) * px, y: y0 + h - CGFloat(y + 1) * px, width: px, height: px).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! icon(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
print("iconset em \(out.path)")
