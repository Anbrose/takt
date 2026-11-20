/// Mirrors packages/core/src/order.ts.
public enum Order {
    /// Moves one element; returns a new array.
    public static func move<T>(_ items: [T], from: Int, to: Int) -> [T] {
        var a = items
        let x = a.remove(at: from)
        a.insert(x, at: to)
        return a
    }

    /// Abbreviation for the drag-time order rail: ASCII names keep 4 characters, others 2 (CJK).
    public static func railAbbr(_ short: String) -> String {
        guard let first = short.unicodeScalars.first else { return "" }
        return String(short.prefix(first.isASCII ? 4 : 2))
    }

    /// Index the dragged row should land on, given row heights, the row's start index and its
    /// vertical offset. A row moves past a neighbour once its centre crosses the neighbour's centre.
    public static func dropIndex(heights: [Double], gap: Double, from: Int, offset: Double) -> Int {
        guard heights.indices.contains(from) else { return from }
        var tops: [Double] = []
        var acc = 0.0
        for h in heights {
            tops.append(acc)
            acc += h + gap
        }
        let centre = tops[from] + heights[from] / 2 + offset
        var to = from
        while to < heights.count - 1, centre > tops[to + 1] + heights[to + 1] / 2 { to += 1 }
        while to > 0, centre < tops[to - 1] + heights[to - 1] / 2 { to -= 1 }
        return to
    }
}
