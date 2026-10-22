// Compartilhado entre o app e o widget: formatos, paleta e as peças do painel.
import SwiftUI

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
let ink = Color(red: 0.16, green: 0.16, blue: 0.16)
let paper = Color(red: 0.91, green: 0.90, blue: 0.87)
let faded = Color(red: 0.55, green: 0.55, blue: 0.53)

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
    var size: CGFloat = 82          // o painel usa 82; o widget, menor
    private let segments = 24

    var body: some View {
        let k = size / 82
        VStack(spacing: 6 * k) {
            ZStack {
                ForEach(0..<segments, id: \.self) { i in
                    let on = Double(i) < pct * Double(segments)
                    Capsule()
                        .fill(on ? ink : ink.opacity(0.15))
                        .frame(width: 4 * k, height: 9 * k)
                        .offset(y: -34 * k)
                        .rotationEffect(.degrees(Double(i) / Double(segments) * 360))
                }
                VStack(spacing: 0) {
                    Text("\(Int((pct * 100).rounded()))%").font(.system(size: 20 * k, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Caption(text: label)
                }
            }
            .frame(width: size, height: size)
            if !footnote.isEmpty {
                Text(footnote).font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).lineLimit(1)
            }
        }
    }
}
