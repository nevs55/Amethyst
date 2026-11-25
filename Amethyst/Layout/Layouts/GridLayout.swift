import Silica

class GridLayout<Window: WindowType>: Layout<Window> {
    override class var layoutName: String { "Grid" }
    override class var layoutKey: String { "builtin-grid" }

    func columnCount(for count: Int) -> Int {
        Int(ceil(sqrt(Double(count))))
    }

    override func frameAssignments(_ windowSet: WindowSet<Window>, on screen: Screen) -> [FrameAssignmentOperation<Window>]? {
        let bounds = screen.adjustedFrame()
        let frames = tileFrames(count: windowSet.windows.count, in: bounds)
        return zip(windowSet.windows, frames).map { window, frame in
            let assignment = FrameAssignment<Window>(frame: frame, window: window, screenFrame: bounds,
                resizeRules: ResizeRules(isMain: true, unconstrainedDimension: .horizontal, scaleFactor: 1))
            return FrameAssignmentOperation(frameAssignment: assignment, windowSet: windowSet)
        }
    }

    func tileFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        gridFrames(count: count, columns: columnCount(for: count), in: bounds)
    }

    fileprivate func gridFrames(count: Int, columns: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let rows = (count - 1) / columns + 1

        // Round shared interior edges and keep the outer edges on the display bounds.
        func offset(_ index: Int, of divisions: Int, along length: CGFloat) -> CGFloat {
            index == divisions ? length : (length * CGFloat(index) / CGFloat(divisions)).rounded()
        }

        return (0..<count).map { index in
            let row = index / columns
            let column = index % columns
            let rowWidth = min(columns, count - row * columns)
            let left = offset(column, of: rowWidth, along: bounds.width)
            let right = offset(column + 1, of: rowWidth, along: bounds.width)
            let top = offset(row, of: rows, along: bounds.height)
            let bottom = offset(row + 1, of: rows, along: bounds.height)
            return CGRect(x: bounds.minX + left, y: bounds.minY + top, width: right - left, height: bottom - top)
        }
    }
}

final class EqualColumnsLayout<Window: WindowType>: GridLayout<Window> {
    override static var layoutName: String { "Equal Columns" }
    override static var layoutKey: String { "builtin-equal-columns" }

    override func columnCount(for count: Int) -> Int { count }
}

final class EqualRowsLayout<Window: WindowType>: GridLayout<Window> {
    override static var layoutName: String { "Equal Rows" }
    override static var layoutKey: String { "builtin-equal-rows" }

    override func columnCount(for count: Int) -> Int { 1 }
}

final class MainLeftGridLayout<Window: WindowType>: GridLayout<Window> {
    override static var layoutName: String { "Main Left + Grid" }
    override static var layoutKey: String { "builtin-main-left-grid" }

    override func tileFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 1 else { return count == 1 ? [bounds] : [] }
        let (main, right) = bounds.divided(atDistance: (bounds.width / 2).rounded(), from: .minXEdge)
        let secondary = count - 1
        let columns = secondary <= 3 ? 1 : columnCount(for: secondary)
        return [main] + gridFrames(count: secondary, columns: columns, in: right)
    }
}

final class TopPairLayout<Window: WindowType>: GridLayout<Window> {
    override static var layoutName: String { "Top Pair + Bottom Row" }
    override static var layoutKey: String { "builtin-top-pair" }

    override func tileFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 2 else { return gridFrames(count: count, columns: 2, in: bounds) }
        let (top, bottom) = bounds.divided(atDistance: (bounds.height * 2 / 3).rounded(), from: .minYEdge)
        return gridFrames(count: 2, columns: 2, in: top) + gridFrames(count: count - 2, columns: count - 2, in: bottom)
    }
}

final class MainBelowLayout<Window: WindowType>: GridLayout<Window> {
    override static var layoutName: String { "Main Below" }
    override static var layoutKey: String { "builtin-main-below" }

    override func tileFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        guard count > 1 else { return count == 1 ? [bounds] : [] }
        let (main, top) = bounds.divided(atDistance: (bounds.height * 2 / 3).rounded(), from: .maxYEdge)
        return [main] + gridFrames(count: count - 1, columns: count - 1, in: top)
    }
}
