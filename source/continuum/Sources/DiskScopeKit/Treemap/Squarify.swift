import CoreGraphics

/// Squarified treemap layout — Bruls, Huizing & van Wijk (2000).
///
/// Partitions a rect into blocks whose areas are exactly proportional to the
/// input weights, greedily keeping every block's aspect ratio as close to 1:1
/// as possible. The returned rects tile the input rect with no gaps and no
/// overlap: the last block of every strip is stretched to the strip edge and
/// the final strip consumes the remaining rect exactly, so floating-point
/// drift can never break the 100%-coverage invariant.
enum Squarify {

    /// `weights` should be sorted descending (callers pass size-sorted children).
    /// Zero or negative weights produce `.zero` rects.
    static func layout(weights: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width >= 1, rect.height >= 1 else { return result }

        let scale = Double(rect.width * rect.height) / total
        let areas = weights.map { max($0, 0) * scale }

        var remaining = rect
        var index = 0
        while index < areas.count {
            guard remaining.width > 0.001, remaining.height > 0.001, areas[index] > 0 else { break }
            let shortSide = Double(min(remaining.width, remaining.height))

            // Grow the row while the next item does not worsen the row's
            // worst aspect ratio.
            var row: [Double] = [areas[index]]
            var next = index + 1
            while next < areas.count, areas[next] > 0,
                  worstAspect(row + [areas[next]], shortSide) <= worstAspect(row, shortSide) {
                row.append(areas[next])
                next += 1
            }

            layoutRow(row, into: &result, at: index, remaining: &remaining,
                      isLastRow: next >= areas.count || areas[next] <= 0)
            index = next
        }
        return result
    }

    /// Worst (largest) aspect ratio in a row laid along a side of length `side`.
    private static func worstAspect(_ row: [Double], _ side: Double) -> Double {
        guard side > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else {
            return .greatestFiniteMagnitude
        }
        let sum = row.reduce(0, +)
        let sum2 = sum * sum
        let side2 = side * side
        return max(side2 * maxArea / sum2, sum2 / (side2 * minArea))
    }

    private static func layoutRow(_ row: [Double], into result: inout [CGRect], at startIndex: Int,
                                  remaining: inout CGRect, isLastRow: Bool) {
        let rowArea = row.reduce(0, +)
        if remaining.width >= remaining.height {
            // Strip along the left edge (items stacked vertically).
            var thickness = remaining.height > 0 ? CGFloat(rowArea) / remaining.height : 0
            if isLastRow { thickness = remaining.width }
            thickness = min(thickness, remaining.width)
            var y = remaining.minY
            for (offset, area) in row.enumerated() {
                var height = thickness > 0 ? CGFloat(area) / thickness : 0
                if offset == row.count - 1 { height = remaining.maxY - y }
                height = max(height, 0)
                result[startIndex + offset] = CGRect(x: remaining.minX, y: y, width: thickness, height: height)
                y += height
            }
            remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                               width: max(remaining.width - thickness, 0), height: remaining.height)
        } else {
            // Strip along the top edge (items laid horizontally).
            var thickness = remaining.width > 0 ? CGFloat(rowArea) / remaining.width : 0
            if isLastRow { thickness = remaining.height }
            thickness = min(thickness, remaining.height)
            var x = remaining.minX
            for (offset, area) in row.enumerated() {
                var width = thickness > 0 ? CGFloat(area) / thickness : 0
                if offset == row.count - 1 { width = remaining.maxX - x }
                width = max(width, 0)
                result[startIndex + offset] = CGRect(x: x, y: remaining.minY, width: width, height: thickness)
                x += width
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                               width: remaining.width, height: max(remaining.height - thickness, 0))
        }
    }
}
