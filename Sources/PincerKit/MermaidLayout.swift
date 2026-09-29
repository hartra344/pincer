import CoreGraphics
import Foundation

/// Flowchart subset: parser, layered layout (Sugiyama-lite) and SVG rendering.
struct MermaidFlowchart {
    enum Shape { case rect, round, stadium, subroutine, cylinder, circle, asym, diamond, hexagon, para, paraAlt, trap, trapAlt }
    enum LineStyle { case solid, dotted, thick, invisible }
    enum Tip { case none, arrow, circle, cross }

    struct Node {
        var id: String
        var label: String
        var shape: Shape
        var subgraph: Int?
    }

    struct Edge {
        var from: Int
        var to: Int
        var style: LineStyle
        var head: Tip
        var tail: Tip
        var label: String?
    }

    struct Subgraph {
        var id: String
        var title: String
        var parent: Int?
    }

    var direction = "TD"
    var nodes: [Node] = []
    var edges: [Edge] = []
    var subgraphs: [Subgraph] = []
    var index: [String: Int] = [:]

    // MARK: Parsing

    static func parse(header: String, lines: [String]) -> MermaidFlowchart? {
        var chart = MermaidFlowchart()
        let words = header.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { String($0).uppercased() }
        if words.count > 1 {
            let d = words[1].trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            switch d {
            case "TD", "TB": chart.direction = "TD"
            case "LR", "RL", "BT": chart.direction = d
            default: break
            }
        }
        var stack: [Int] = []
        var parser = StatementParser()
        for rawLine in lines {
            for statement in splitStatements(rawLine) {
                if chart.nodes.count > MermaidSource.maxNodes || chart.edges.count > MermaidSource.maxEdges { return nil }
                chart.handle(statement, stack: &stack, parser: &parser)
            }
        }
        guard !chart.nodes.isEmpty,
              chart.nodes.count <= MermaidSource.maxNodes, chart.edges.count <= MermaidSource.maxEdges else { return nil }
        return chart
    }

    static func splitStatements(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        for c in line {
            if c == "\"" { inQuote.toggle() }
            if c == ";" && !inQuote {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static let ignoredKeywords: Set<String> = [
        "classdef", "class", "style", "linkstyle", "click", "direction", "acctitle", "accdescr", "callback", "link",
    ]

    mutating func handle(_ statement: String, stack: inout [Int], parser: inout StatementParser) {
        let firstWord = statement.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? statement
        let lower = firstWord.lowercased()
        if lower == "end" { _ = stack.popLast(); return }
        if lower == "subgraph" {
            var rest = String(statement.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)
            var id = rest, title = rest
            if let open = rest.firstIndex(of: "["), rest.hasSuffix("]") {
                id = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
                title = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            }
            rest = ""
            subgraphs.append(Subgraph(id: id, title: MermaidSource.cleanLabel(title), parent: stack.last))
            stack.append(subgraphs.count - 1)
            return
        }
        if Self.ignoredKeywords.contains(lower), statement.count == firstWord.count || statement.dropFirst(firstWord.count).first == " " {
            return
        }
        parser.parse(statement, into: &self, subgraph: stack.last)
    }

    mutating func node(id: String, label: String?, shape: Shape?, subgraph: Int?) -> Int {
        if let existing = index[id] {
            if let label { nodes[existing].label = label }
            if let shape { nodes[existing].shape = shape }
            if nodes[existing].subgraph == nil { nodes[existing].subgraph = subgraph }
            return existing
        }
        nodes.append(Node(id: id, label: label ?? id, shape: shape ?? .rect, subgraph: subgraph))
        index[id] = nodes.count - 1
        return nodes.count - 1
    }

    struct EdgeOp {
        var style: LineStyle
        var head: Tip
        var tail: Tip
        var label: String?
    }

    /// Scans one statement: `A & B --> C -->|x| D`.
    struct StatementParser {
        let patterns: [(NSRegularExpression, Int)] = {
            // Second element: pattern kind (0 = labelled solid, 1 = labelled thick, 2 = labelled dotted, 3 = plain, 4 = plain dotted, 5 = invisible)
            let sources: [(String, Int)] = [
                (#"^(<)?--\s+(.+?)\s+(-{2,})([>ox])?"#, 0),
                (#"^(<)?==\s+(.+?)\s+(={2,})([>ox])?"#, 1),
                (#"^(<)?-\.\s+(.+?)\s+\.+-(>)?"#, 2),
                (#"^(<)?(-{2,}|={2,})([>ox])?"#, 3),
                (#"^(<)?-\.+-(>)?"#, 4),
                (#"^~~~+"#, 5),
            ]
            return sources.compactMap { source, kind in
                (try? NSRegularExpression(pattern: source)).map { ($0, kind) }
            }
        }()

        func tip(_ c: String) -> Tip {
            switch c {
            case ">": .arrow
            case "o": .circle
            case "x": .cross
            default: .none
            }
        }

        func edgeOp(_ chars: [Character], _ i: inout Int) -> EdgeOp? {
            while i < chars.count, chars[i] == " " { i += 1 }
            let rest = String(chars[i...])
            let ns = rest as NSString
            let full = NSRange(location: 0, length: ns.length)
            for (regex, kind) in patterns {
                guard let match = regex.firstMatch(in: rest, options: [.anchored], range: full) else { continue }
                func group(_ k: Int) -> String? {
                    k < match.numberOfRanges && match.range(at: k).location != NSNotFound ? ns.substring(with: match.range(at: k)) : nil
                }
                var op: EdgeOp
                switch kind {
                case 0: op = EdgeOp(style: .solid, head: tip(group(4) ?? ""), tail: group(1) != nil ? .arrow : .none, label: group(2))
                case 1: op = EdgeOp(style: .thick, head: tip(group(4) ?? ""), tail: group(1) != nil ? .arrow : .none, label: group(2))
                case 2: op = EdgeOp(style: .dotted, head: tip(group(3) ?? ""), tail: group(1) != nil ? .arrow : .none, label: group(2))
                case 3:
                    op = EdgeOp(style: (group(2) ?? "-").hasPrefix("=") ? .thick : .solid, head: tip(group(3) ?? ""),
                                tail: group(1) != nil ? .arrow : .none, label: nil)
                case 4: op = EdgeOp(style: .dotted, head: tip(group(2) ?? ""), tail: group(1) != nil ? .arrow : .none, label: nil)
                default: op = EdgeOp(style: .invisible, head: .none, tail: .none, label: nil)
                }
                // Consume the operator, whole-character aligned.
                let consumedString = ns.substring(with: NSRange(location: 0, length: match.range.length))
                i += consumedString.count
                while i < chars.count, chars[i] == " " { i += 1 }
                if i < chars.count, chars[i] == "|", let close = chars[(i + 1)...].firstIndex(of: "|") {
                    op.label = String(chars[(i + 1)..<close])
                    i = close + 1
                }
                if let label = op.label {
                    let cleaned = MermaidSource.cleanLabel(label)
                    op.label = cleaned.isEmpty ? nil : cleaned
                }
                return op
            }
            return nil
        }

        static let openers: [(String, String, Shape)] = [
            ("([", "])", .stadium), ("[[", "]]", .subroutine), ("[(", ")]", .cylinder), ("((", "))", .circle),
            ("{{", "}}", .hexagon), ("[", "]", .rect), ("(", ")", .round), ("{", "}", .diamond), (">", "]", .asym),
        ]

        func isIDChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        /// Parses `id`, optionally followed by a shape and label.
        func node(_ chars: [Character], _ i: inout Int) -> (id: String, label: String?, shape: Shape?)? {
            while i < chars.count, chars[i] == " " { i += 1 }
            let start = i
            while i < chars.count, isIDChar(chars[i]) { i += 1 }
            guard i > start else { return nil }
            let id = String(chars[start..<i])
            var label: String?
            var shape: Shape?
            if i < chars.count, "[({>".contains(chars[i]) {
                let rest = String(chars[i...])
                var opener: (String, String, Shape)?
                if rest.hasPrefix("[/") || rest.hasPrefix("[\\") {
                    let leading = rest.dropFirst().first!
                    opener = (String(rest.prefix(2)), "", leading == "/" ? .para : .paraAlt)
                } else {
                    opener = Self.openers.first { rest.hasPrefix($0.0) }
                }
                if let opener {
                    let openCount = opener.0.count
                    var body = Array(chars[(i + openCount)...])
                    var searchFrom = 0
                    var quoted: String?
                    if body.first == "\"", let q = body.dropFirst().firstIndex(of: "\"") {
                        quoted = String(body[1..<q])
                        searchFrom = q + 1
                    }
                    var end: Int?
                    var closeLen = 0
                    var finalShape = opener.2
                    if opener.1.isEmpty {
                        for k in searchFrom..<max(searchFrom, body.count - 1) where body[k + 1] == "]" && (body[k] == "/" || body[k] == "\\") {
                            end = k
                            closeLen = 2
                            let slashClose = body[k] == "/"
                            finalShape = opener.2 == .para ? (slashClose ? .para : .trap) : (slashClose ? .trapAlt : .paraAlt)
                            break
                        }
                    } else {
                        let closer = Array(opener.1)
                        if body.count >= closer.count {
                            for k in searchFrom...(body.count - closer.count) where Array(body[k..<(k + closer.count)]) == closer {
                                end = k
                                closeLen = closer.count
                                break
                            }
                        }
                    }
                    guard let end else { return nil }
                    label = MermaidSource.cleanLabel(quoted ?? String(body[..<end]))
                    if label?.isEmpty == true { label = id }
                    shape = finalShape
                    i += openCount + end + closeLen
                    body.removeAll()
                }
            }
            if i + 2 < chars.count, chars[i] == ":", chars[i + 1] == ":", chars[i + 2] == ":" {
                i += 3
                while i < chars.count, isIDChar(chars[i]) || chars[i] == "-" { i += 1 }
            }
            return (id, label, shape)
        }

        func parse(_ statement: String, into chart: inout MermaidFlowchart, subgraph: Int?) {
            let chars = Array(statement)
            var i = 0
            var previous: [Int]?
            var pendingOp: EdgeOp?
            while i < chars.count {
                var group: [Int] = []
                guard let first = node(chars, &i) else { break }
                group.append(chart.node(id: first.id, label: first.label, shape: first.shape, subgraph: subgraph))
                while true {
                    var j = i
                    while j < chars.count, chars[j] == " " { j += 1 }
                    guard j < chars.count, chars[j] == "&" else { break }
                    j += 1
                    guard let next = node(chars, &j) else { break }
                    i = j
                    group.append(chart.node(id: next.id, label: next.label, shape: next.shape, subgraph: subgraph))
                }
                if let previous, let op = pendingOp {
                    for from in previous {
                        for to in group {
                            chart.edges.append(Edge(from: from, to: to, style: op.style, head: op.head, tail: op.tail, label: op.label))
                        }
                    }
                }
                previous = group
                pendingOp = edgeOp(chars, &i)
                if pendingOp == nil { break }
            }
        }
    }
}

// MARK: - Layout

extension MermaidFlowchart {
    struct Layout {
        var rects: [CGRect]
        var paths: [[CGPoint]]
        var labelCenters: [CGPoint?]
        var subgraphRects: [CGRect?]
    }

    static let fontSize: CGFloat = 14
    static let lineHeight: CGFloat = 18

    func size(of node: Node) -> CGSize {
        let lines = MermaidSource.textLines(node.label)
        let tw = MermaidSource.maxWidth(lines, size: Self.fontSize)
        let th = CGFloat(lines.count) * Self.lineHeight
        switch node.shape {
        case .diamond:
            return CGSize(width: max(70, tw * 1.5 + 30), height: max(50, th * 1.6 + 20))
        case .circle:
            let d = max(46, (tw * tw + th * th).squareRoot() + 20)
            return CGSize(width: d, height: d)
        case .hexagon:
            return CGSize(width: max(60, tw + 52), height: max(38, th + 20))
        case .stadium:
            return CGSize(width: max(60, tw + 44), height: max(38, th + 18))
        case .cylinder:
            return CGSize(width: max(60, tw + 30), height: max(50, th + 34))
        case .para, .paraAlt, .trap, .trapAlt, .asym:
            return CGSize(width: max(60, tw + 46), height: max(38, th + 18))
        case .subroutine:
            return CGSize(width: max(60, tw + 44), height: max(38, th + 18))
        case .rect, .round:
            return CGSize(width: max(50, tw + 30), height: max(38, th + 18))
        }
    }

    func layout() -> Layout {
        let count = nodes.count
        let vertical = direction == "TD" || direction == "BT"
        // Items are real nodes [0, count) then dummies for edges spanning several ranks.
        var cross: [CGFloat] = []
        var along: [CGFloat] = []
        for node in nodes {
            let s = size(of: node)
            cross.append(vertical ? s.width : s.height)
            along.append(vertical ? s.height : s.width)
        }

        // Cycle breaking: DFS back-edges are reversed.
        var outgoing = Array(repeating: [Int](), count: count)
        for (k, edge) in edges.enumerated() where edge.from != edge.to { outgoing[edge.from].append(k) }
        var state = Array(repeating: 0, count: count)
        var reversed = Set<Int>()
        func visit(_ u: Int) {
            state[u] = 1
            for k in outgoing[u] {
                let v = edges[k].to
                if state[v] == 1 { reversed.insert(k) } else if state[v] == 0 { visit(v) }
            }
            state[u] = 2
        }
        for u in 0..<count where state[u] == 0 { visit(u) }

        func oriented(_ k: Int) -> (Int, Int) {
            reversed.contains(k) ? (edges[k].to, edges[k].from) : (edges[k].from, edges[k].to)
        }
        let layoutEdges = edges.indices.filter { edges[$0].from != edges[$0].to }

        var rank = Array(repeating: 0, count: count)
        var indegree = Array(repeating: 0, count: count)
        var successors = Array(repeating: [Int](), count: count)
        for k in layoutEdges {
            let (u, v) = oriented(k)
            successors[u].append(v)
            indegree[v] += 1
        }
        var queue = (0..<count).filter { indegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            for v in successors[u] {
                rank[v] = max(rank[v], rank[u] + 1)
                indegree[v] -= 1
                if indegree[v] == 0 { queue.append(v) }
            }
        }

        var itemRank = rank
        var chains: [Int: [Int]] = [:]
        for k in layoutEdges {
            let (u, v) = oriented(k)
            var chain = [u]
            if rank[v] - rank[u] > 1 {
                for r in (rank[u] + 1)..<rank[v] {
                    itemRank.append(r)
                    cross.append(12)
                    along.append(0)
                    chain.append(itemRank.count - 1)
                }
            }
            chain.append(v)
            chains[k] = chain
        }
        let total = itemRank.count
        var up = Array(repeating: [Int](), count: total)
        var down = Array(repeating: [Int](), count: total)
        for k in layoutEdges {
            let chain = chains[k]!
            for pair in zip(chain, chain.dropFirst()) {
                down[pair.0].append(pair.1)
                up[pair.1].append(pair.0)
            }
        }

        let layerCount = (itemRank.max() ?? 0) + 1
        var layers = Array(repeating: [Int](), count: layerCount)
        for item in 0..<total { layers[itemRank[item]].append(item) }

        var position = Array(repeating: 0, count: total)
        func refreshPositions() {
            for layer in layers { for (p, item) in layer.enumerated() { position[item] = p } }
        }
        refreshPositions()
        func sweep(_ layerIndex: Int, neighbors: [[Int]]) {
            let current = layers[layerIndex]
            var keyed: [(Double, Int, Int)] = []
            for (p, item) in current.enumerated() {
                let ns = neighbors[item]
                let key = ns.isEmpty ? Double(p) : Double(ns.map { position[$0] }.reduce(0, +)) / Double(ns.count)
                keyed.append((key, p, item))
            }
            keyed.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            layers[layerIndex] = keyed.map { $0.2 }
            for (p, item) in layers[layerIndex].enumerated() { position[item] = p }
        }
        for _ in 0..<4 {
            if layerCount > 1 {
                for l in 1..<layerCount { sweep(l, neighbors: up) }
                for l in stride(from: layerCount - 2, through: 0, by: -1) { sweep(l, neighbors: down) }
            }
        }

        // Cross-axis coordinates.
        func gap(_ a: Int, _ b: Int) -> CGFloat { (a >= count || b >= count) ? 20 : 40 }
        func separation(_ a: Int, _ b: Int) -> CGFloat { cross[a] / 2 + cross[b] / 2 + gap(a, b) }
        var coordinate = Array(repeating: CGFloat(0), count: total)
        for layer in layers {
            var cursor: CGFloat = 0
            for (p, item) in layer.enumerated() {
                if p > 0 { cursor += separation(layer[p - 1], item) }
                coordinate[item] = cursor
            }
        }
        func place(_ layer: [Int], neighbors: [[Int]]) {
            guard !layer.isEmpty else { return }
            let desired = layer.map { item -> CGFloat in
                let ns = neighbors[item]
                return ns.isEmpty ? coordinate[item] : ns.map { coordinate[$0] }.reduce(0, +) / CGFloat(ns.count)
            }
            var forward = desired, backward = desired
            for p in 1..<max(layer.count, 1) where p < layer.count {
                forward[p] = max(desired[p], forward[p - 1] + separation(layer[p - 1], layer[p]))
            }
            for p in stride(from: layer.count - 2, through: 0, by: -1) {
                backward[p] = min(desired[p], backward[p + 1] - separation(layer[p], layer[p + 1]))
            }
            for (p, item) in layer.enumerated() { coordinate[item] = (forward[p] + backward[p]) / 2 }
        }
        for _ in 0..<6 {
            if layerCount > 1 {
                for l in 1..<layerCount { place(layers[l], neighbors: up) }
                for l in stride(from: layerCount - 2, through: 0, by: -1) { place(layers[l], neighbors: down) }
            }
        }

        // Rank-axis coordinates.
        let hasLabels = edges.contains { $0.label != nil }
        var rankGap: CGFloat = hasLabels ? 72 : 56
        if !vertical, hasLabels {
            let widest = edges.compactMap(\.label).map { MermaidSource.maxWidth(MermaidSource.textLines($0), size: 12) }.max() ?? 0
            rankGap = max(rankGap, widest + 40)
        }
        var alongCenter = Array(repeating: CGFloat(0), count: layerCount)
        var cursor: CGFloat = 0
        for l in 0..<layerCount {
            let thickness = layers[l].map { along[$0] }.max() ?? 0
            alongCenter[l] = cursor + thickness / 2
            cursor += thickness + (thickness == 0 ? rankGap / 3 : rankGap)
        }
        let totalAlong = max(cursor - rankGap, 0)

        func point(_ item: Int) -> CGPoint {
            var a = alongCenter[itemRank[item]]
            let c = coordinate[item]
            if direction == "BT" || direction == "RL" { a = totalAlong - a }
            return vertical ? CGPoint(x: c, y: a) : CGPoint(x: a, y: c)
        }
        var rects: [CGRect] = []
        for k in 0..<count {
            let s = size(of: nodes[k])
            let p = point(k)
            rects.append(CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
        }

        var paths = Array(repeating: [CGPoint](), count: edges.count)
        var labelCenters = Array<CGPoint?>(repeating: nil, count: edges.count)
        for (k, edge) in edges.enumerated() {
            if edge.from == edge.to {
                let r = rects[edge.from]
                let start = CGPoint(x: r.maxX, y: r.midY - 8)
                paths[k] = [start, CGPoint(x: r.maxX + 26, y: start.y), CGPoint(x: r.maxX + 26, y: r.midY + 8),
                            CGPoint(x: r.maxX, y: r.midY + 8)]
                if edge.label != nil { labelCenters[k] = CGPoint(x: r.maxX + 26, y: r.midY) }
                continue
            }
            var points = chains[k]!.map(point)
            if reversed.contains(k) { points.reverse() }
            points[0] = Self.clip(rects[edge.from], nodes[edge.from].shape, toward: points[1], from: points[0])
            let last = points.count - 1
            points[last] = Self.clip(rects[edge.to], nodes[edge.to].shape, toward: points[last - 1], from: points[last])
            paths[k] = points
            if edge.label != nil { labelCenters[k] = Self.midpoint(points) }
        }

        var subgraphRects = Array<CGRect?>(repeating: nil, count: subgraphs.count)
        func bounds(_ s: Int) -> CGRect? {
            var rect: CGRect?
            for (k, node) in nodes.enumerated() where node.subgraph == s { rect = rect.map { $0.union(rects[k]) } ?? rects[k] }
            for (c, sub) in subgraphs.enumerated() where sub.parent == s {
                if let inner = bounds(c) { rect = rect.map { $0.union(inner) } ?? inner }
            }
            guard let rect else { return nil }
            let titleWidth = MermaidSource.maxWidth(MermaidSource.textLines(subgraphs[s].title), size: 13, bold: true) + 24
            var padded = CGRect(x: rect.minX - 16, y: rect.minY - 32, width: rect.width + 32, height: rect.height + 48)
            if padded.width < titleWidth {
                padded = CGRect(x: padded.midX - titleWidth / 2, y: padded.minY, width: titleWidth, height: padded.height)
            }
            subgraphRects[s] = padded
            return padded
        }
        for s in subgraphs.indices where subgraphs[s].parent == nil { _ = bounds(s) }
        return Layout(rects: rects, paths: paths, labelCenters: labelCenters, subgraphRects: subgraphRects)
    }

    static func midpoint(_ points: [CGPoint]) -> CGPoint {
        var lengths: [CGFloat] = []
        for pair in zip(points, points.dropFirst()) { lengths.append(hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)) }
        var remaining = lengths.reduce(0, +) / 2
        for (k, length) in lengths.enumerated() {
            if remaining <= length || k == lengths.count - 1 {
                let t = length > 0 ? remaining / length : 0
                return CGPoint(x: points[k].x + (points[k + 1].x - points[k].x) * t,
                               y: points[k].y + (points[k + 1].y - points[k].y) * t)
            }
            remaining -= length
        }
        return points[0]
    }

    /// Point where the ray from `center` toward `target` leaves the node outline.
    static func clip(_ rect: CGRect, _ shape: Shape, toward target: CGPoint, from center: CGPoint) -> CGPoint {
        let dx = target.x - center.x, dy = target.y - center.y
        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return center }
        let hw = rect.width / 2, hh = rect.height / 2
        let t: CGFloat
        switch shape {
        case .diamond:
            t = 1 / (abs(dx) / hw + abs(dy) / hh)
        case .circle:
            t = 1 / ((dx * dx) / (hw * hw) + (dy * dy) / (hh * hh)).squareRoot()
        default:
            t = min(abs(dx) > 0.001 ? hw / abs(dx) : .infinity, abs(dy) > 0.001 ? hh / abs(dy) : .infinity)
        }
        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }
}

// MARK: - Rendering

extension MermaidFlowchart {
    func render(theme: RichRenderSVG.Theme) -> MermaidSource.Canvas? {
        let palette = RichRenderSVG.palette(theme)
        let layout = layout()
        var canvas = MermaidSource.Canvas()
        let n = MermaidSource.n

        // Subgraph frames, outermost first so nested ones draw on top.
        func depth(_ s: Int) -> Int { subgraphs[s].parent.map { depth($0) + 1 } ?? 0 }
        for s in subgraphs.indices.sorted(by: { (depth($0), $0) < (depth($1), $1) }) {
            guard let r = layout.subgraphRects[s] else { continue }
            canvas.include(r)
            canvas.add(#"<rect x="\#(n(r.minX))" y="\#(n(r.minY))" width="\#(n(r.width))" height="\#(n(r.height))" rx="8" fill="\#(palette.accentFill)" stroke="\#(palette.border)"/>"#)
            canvas.add(MermaidSource.textBlock(centerX: r.midX, centerY: r.minY + 15, lines: [subgraphs[s].title], size: 13,
                                               fill: palette.secondaryText, lineHeight: 16, bold: true))
        }

        for (k, edge) in edges.enumerated() where edge.style != .invisible {
            var points = layout.paths[k]
            guard points.count >= 2 else { continue }
            var extras = ""
            let last = points.count - 1
            func end(_ tip: Tip, at index: Int, neighbor: Int) {
                let tipPoint = points[index], from = points[neighbor]
                switch tip {
                case .none: break
                case .arrow:
                    extras += MermaidSource.arrowHead(tip: tipPoint, from: from, fill: palette.edge)
                    let dx = tipPoint.x - from.x, dy = tipPoint.y - from.y
                    let d = max(hypot(dx, dy), 0.001)
                    points[index] = CGPoint(x: tipPoint.x - dx / d * 8, y: tipPoint.y - dy / d * 8)
                case .circle:
                    let dx = tipPoint.x - from.x, dy = tipPoint.y - from.y
                    let d = max(hypot(dx, dy), 0.001)
                    let c = CGPoint(x: tipPoint.x - dx / d * 5, y: tipPoint.y - dy / d * 5)
                    extras += #"<circle cx="\#(n(c.x))" cy="\#(n(c.y))" r="4.5" fill="\#(palette.background)" stroke="\#(palette.edge)" stroke-width="1.5"/>"#
                    points[index] = CGPoint(x: tipPoint.x - dx / d * 10, y: tipPoint.y - dy / d * 10)
                case .cross:
                    let dx = tipPoint.x - from.x, dy = tipPoint.y - from.y
                    let d = max(hypot(dx, dy), 0.001)
                    let c = CGPoint(x: tipPoint.x - dx / d * 6, y: tipPoint.y - dy / d * 6)
                    extras += #"<line x1="\#(n(c.x - 4))" y1="\#(n(c.y - 4))" x2="\#(n(c.x + 4))" y2="\#(n(c.y + 4))" stroke="\#(palette.edge)" stroke-width="2"/>"#
                    extras += #"<line x1="\#(n(c.x - 4))" y1="\#(n(c.y + 4))" x2="\#(n(c.x + 4))" y2="\#(n(c.y - 4))" stroke="\#(palette.edge)" stroke-width="2"/>"#
                    points[index] = CGPoint(x: tipPoint.x - dx / d * 10, y: tipPoint.y - dy / d * 10)
                }
            }
            let original = points
            end(edge.head, at: last, neighbor: last - 1)
            if edge.tail != .none {
                let saved = points
                points = original
                points[last] = saved[last]
                end(edge.tail, at: 0, neighbor: 1)
            }
            let width: String = edge.style == .thick ? "3" : "1.5"
            let dash = edge.style == .dotted ? #" stroke-dasharray="4 4""# : ""
            let d = points.enumerated().map { "\($0.offset == 0 ? "M" : "L")\(n($0.element.x)) \(n($0.element.y))" }.joined(separator: " ")
            canvas.add(#"<path d="\#(d)" fill="none" stroke="\#(palette.edge)" stroke-width="\#(width)"\#(dash) stroke-linejoin="round"/>"#)
            canvas.add(extras)
            for p in layout.paths[k] { canvas.include(p) }
        }

        for (k, node) in nodes.enumerated() {
            canvas.include(layout.rects[k])
            canvas.add(Self.shapeSVG(node.shape, layout.rects[k], palette: palette))
            canvas.add(MermaidSource.textBlock(centerX: layout.rects[k].midX, centerY: layout.rects[k].midY,
                                               lines: MermaidSource.textLines(node.label), size: Self.fontSize,
                                               fill: palette.text, lineHeight: Self.lineHeight))
        }

        for (k, edge) in edges.enumerated() where edge.style != .invisible {
            guard let label = edge.label, let center = layout.labelCenters[k] else { continue }
            let lines = MermaidSource.textLines(label)
            let w = MermaidSource.maxWidth(lines, size: 12) + 10
            let h = CGFloat(lines.count) * 15 + 4
            let box = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            canvas.include(box)
            canvas.add(#"<rect x="\#(n(box.minX))" y="\#(n(box.minY))" width="\#(n(w))" height="\#(n(h))" rx="3" fill="\#(palette.background)"/>"#)
            canvas.add(MermaidSource.textBlock(centerX: center.x, centerY: center.y, lines: lines, size: 12,
                                               fill: palette.secondaryText, lineHeight: 15))
        }
        return canvas.isEmpty ? nil : canvas
    }

    static func shapeSVG(_ shape: Shape, _ r: CGRect, palette: RichRenderSVG.Palette) -> String {
        let n = MermaidSource.n
        let style = #"fill="\#(palette.nodeFill)" stroke="\#(palette.nodeStroke)" stroke-width="1.5""#
        func polygon(_ pts: [(CGFloat, CGFloat)]) -> String {
            #"<polygon points="\#(pts.map { "\(n($0.0)),\(n($0.1))" }.joined(separator: " "))" \#(style)/>"#
        }
        func rect(rx: CGFloat) -> String {
            #"<rect x="\#(n(r.minX))" y="\#(n(r.minY))" width="\#(n(r.width))" height="\#(n(r.height))" rx="\#(n(rx))" \#(style)/>"#
        }
        let skew: CGFloat = 12
        switch shape {
        case .rect: return rect(rx: 3)
        case .round: return rect(rx: 10)
        case .stadium: return rect(rx: r.height / 2)
        case .subroutine:
            return rect(rx: 2)
                + #"<line x1="\#(n(r.minX + 8))" y1="\#(n(r.minY))" x2="\#(n(r.minX + 8))" y2="\#(n(r.maxY))" stroke="\#(palette.nodeStroke)" stroke-width="1.5"/>"#
                + #"<line x1="\#(n(r.maxX - 8))" y1="\#(n(r.minY))" x2="\#(n(r.maxX - 8))" y2="\#(n(r.maxY))" stroke="\#(palette.nodeStroke)" stroke-width="1.5"/>"#
        case .circle:
            return #"<ellipse cx="\#(n(r.midX))" cy="\#(n(r.midY))" rx="\#(n(r.width / 2))" ry="\#(n(r.height / 2))" \#(style)/>"#
        case .diamond:
            return polygon([(r.midX, r.minY), (r.maxX, r.midY), (r.midX, r.maxY), (r.minX, r.midY)])
        case .hexagon:
            return polygon([(r.minX + 14, r.minY), (r.maxX - 14, r.minY), (r.maxX, r.midY), (r.maxX - 14, r.maxY),
                            (r.minX + 14, r.maxY), (r.minX, r.midY)])
        case .asym:
            return polygon([(r.minX, r.minY), (r.maxX, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY), (r.minX + 12, r.midY)])
        case .para:
            return polygon([(r.minX + skew, r.minY), (r.maxX, r.minY), (r.maxX - skew, r.maxY), (r.minX, r.maxY)])
        case .paraAlt:
            return polygon([(r.minX, r.minY), (r.maxX - skew, r.minY), (r.maxX, r.maxY), (r.minX + skew, r.maxY)])
        case .trap:
            return polygon([(r.minX + skew, r.minY), (r.maxX - skew, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY)])
        case .trapAlt:
            return polygon([(r.minX, r.minY), (r.maxX, r.minY), (r.maxX - skew, r.maxY), (r.minX + skew, r.maxY)])
        case .cylinder:
            let ry: CGFloat = 7
            let body = "M\(n(r.minX)) \(n(r.minY + ry)) A\(n(r.width / 2)) \(n(ry)) 0 0 1 \(n(r.maxX)) \(n(r.minY + ry)) L\(n(r.maxX)) \(n(r.maxY - ry)) A\(n(r.width / 2)) \(n(ry)) 0 0 1 \(n(r.minX)) \(n(r.maxY - ry)) Z"
            let lip = "M\(n(r.minX)) \(n(r.minY + ry)) A\(n(r.width / 2)) \(n(ry)) 0 0 0 \(n(r.maxX)) \(n(r.minY + ry))"
            return #"<path d="\#(body)" \#(style)/>"# + #"<path d="\#(lip)" fill="none" stroke="\#(palette.nodeStroke)" stroke-width="1.5"/>"#
        }
    }
}
