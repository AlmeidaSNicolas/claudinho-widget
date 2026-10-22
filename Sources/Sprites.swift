import AppKit

// Claudinho chef em pixel art. '#' = pixel aceso. Canvas 27x16:
// personagem em x=0 (12 colunas), utensílio em x=13 (14 colunas).

enum ChefState: String, Codable {
    case thinking, chopping, frying, seasoning, plating, waiting, asking, resting

    var title: String {
        switch self {
        case .thinking: "Cozinhando…"
        case .chopping: "Cortando cebola…"
        case .frying: "Na frigideira…"
        case .seasoning: "Temperando…"
        case .plating: "Prato pronto!"
        case .waiting: "Esperando você"
        case .asking: "Pedindo permissão!"
        case .resting: "Descansando"
        }
    }

    var animated: Bool { self != .waiting && self != .resting }

    var subtitle: String {
        switch self {
        case .thinking: "pensando"
        case .chopping: "editando arquivo"
        case .frying: "rodando comando"
        case .seasoning: "lendo e pesquisando"
        case .plating: "terminou a tarefa"
        case .waiting: "sua vez"
        case .asking: "aprove no Claude Code"
        case .resting: "sem atividade"
        }
    }
}

typealias Grid = [[Bool]]

enum Sprites {
    static let width = 27, height = 16

    private static let hat = [
        "..##.##.##..",
        ".##########.",
        ".##########.",
        "..########..",
        "...######...",
    ]
    private static let eyesOpen = [".##.####.##.", ".##.####.##."]
    private static let eyesClosed = [".##########.", ".##.####.##."]
    private static let armsDown = [".##########.", "############", "############", ".##########."]
    private static let armsUp = ["############", "############", ".##########.", ".##########."]

    private static func chef(eyesShut: Bool, armsRaised: Bool) -> [String] {
        hat + [".##########.", ".##########."]
            + (eyesShut ? eyesClosed : eyesOpen)
            + (armsRaised ? armsUp : armsDown)
            + [".##########.", "..#.#..#.#..", "..#.#..#.#.."]
    }

    // Camadas do utensílio: (desenho, x, y) relativos ao canto do utensílio.
    private typealias Layer = ([String], Int, Int)

    private static let pot = ["############", ".##########.", ".##########.", ".##########.", ".##########.", "..########..", "..#......#.."]
    private static let steamA = ["#...#", ".#...#", "#...#", ".#...#"]
    private static let steamB = [".#...#", "#...#", ".#...#", "#...#"]
    private static let spoonA = ["..#", ".#.", "#.."]
    private static let spoonB = ["#..", ".#.", "..#"]

    private static let board = ["##############", "##############", ".#..........#."]
    private static let knife = ["##", "##", "##", "####", "###", "###", "###", "##"]
    private static let onion = ["#.#", ".#."]

    private static let pan = [".#########....", "..#######.####", "...#####......"]
    private static let egg = ["###", "###"]
    private static let flameA = ["#.#.#.#"]
    private static let flameB = [".#.#.#."]

    private static let shaker = [".##.", "####", "####", "####", "####"]
    private static let dropsA = ["#..", "...", ".#.", "...", "#.."]
    private static let dropsB = [".#.", "#..", "...", ".#.", "..."]
    private static let bowl = [".##########.", "..########..", "...######..."]

    private static let cloche = ["....##....", "..######..", ".########.", "##########", "##########", "##########"]
    private static let plate = ["##############", ".############."]
    private static let spark = [".#.", "###", ".#."]

    private static let bubble = [
        ".##########.",
        "#..........#",
        "#...####...#",
        "#..#....#..#",
        "#......#...#",
        "#.....#....#",
        "#..........#",
        "#.....#....#",
        ".#######.##.",
        "........#...",
    ]
    private static let bang = [
        ".##########.",
        "#..........#",
        "#....##....#",
        "#....##....#",
        "#....##....#",
        "#....##....#",
        "#..........#",
        "#....##....#",
        ".#######.##.",
        "........#...",
    ]
    private static let bell = ["...#...", "..###..", ".#####.", "#######"]

    private static let zBig = ["####", "..#.", ".#..", "####"]
    private static let zSmall = ["###", ".#.", "###"]
    private static let mug = ["#####..", "#####.#", "#####.#", "######.", ".####.."]

    private static func propLayers(_ state: ChefState, frame: Int) -> [Layer] {
        let a = frame % 2 == 0
        switch state {
        case .thinking:
            return [(pot, 1, 9), (a ? steamA : steamB, 4, 2), (a ? spoonA : spoonB, 8, 6)]
        case .chopping:
            return [(board, 0, 13), (knife, 5, a ? 3 : 5), (onion, 10, 11)]
        case .frying:
            return [(pan, 0, 12), (egg, 3, a ? 10 : 6), (a ? flameA : flameB, 2, 15)]
        case .seasoning:
            return [(shaker, 4, 0), (a ? dropsA : dropsB, 4, 6), (bowl, 1, 13)]
        case .plating:
            return [(cloche, 2, 8), (plate, 0, 14), (spark, a ? 0 : 11, a ? 3 : 1), (spark, a ? 11 : 1, a ? 0 : 4)]
        case .waiting:
            return [(bubble, 1, a ? 0 : 1), (bell, 3, 12)]
        case .asking:
            return [(bang, 1, a ? 0 : 1), (bell, a ? 3 : 4, 12)]
        case .resting:
            return [(zBig, 6, a ? 1 : 2), (zSmall, 2, a ? 5 : 4), (mug, 3, 11)]
        }
    }

    static func grid(_ state: ChefState, frame: Int) -> Grid {
        var g = Grid(repeating: Array(repeating: false, count: width), count: height)
        func stamp(_ rows: [String], _ x: Int, _ y: Int) {
            for (dy, row) in rows.enumerated() {
                for (dx, ch) in row.enumerated() where ch == "#" {
                    let px = x + dx, py = y + dy
                    if px >= 0, px < width, py >= 0, py < height { g[py][px] = true }
                }
            }
        }
        let busy = [.thinking, .chopping, .frying, .seasoning].contains(state)
        let shut = state == .resting || (state != .waiting && frame % 6 == 5) // pisca de vez em quando
        stamp(chef(eyesShut: shut, armsRaised: busy && frame % 2 == 1), 0, 0)
        for (rows, x, y) in propLayers(state, frame: frame) { stamp(rows, 13 + x, y) }
        return g
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ state: ChefState, frame: Int, pixel: CGFloat, color: NSColor, template: Bool) -> NSImage {
        let key = "\(state)-\(frame % 6)-\(pixel)-\(template)"
        if let img = cache[key] { return img }
        let g = grid(state, frame: frame % 6)
        let size = NSSize(width: CGFloat(width) * pixel, height: CGFloat(height) * pixel)
        let img = NSImage(size: size, flipped: true) { _ in
            color.setFill()
            for (y, row) in g.enumerated() {
                for (x, on) in row.enumerated() where on {
                    NSRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel).fill()
                }
            }
            return true
        }
        img.isTemplate = template
        cache[key] = img
        return img
    }
}
