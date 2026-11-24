import Silica

class GridLayout<Window: WindowType>: Layout<Window> {
    override class var layoutName: String { "Grid" }
    override class var layoutKey: String { "builtin-grid" }

    func columnCount(for count: Int) -> Int {
        Int(ceil(sqrt(Double(count))))
    }

    override func frameAssignments(_ windowSet: WindowSet<Window>, on screen: Screen) -> [FrameAssignmentOperation<Window>]? {
        let count = windowSet.windows.count
        guard count > 0 else { return [] }
        let columns = columnCount(for: count)
        let rows = (count - 1) / columns + 1
        let bounds = screen.adjustedFrame()

        // Round shared interior edges and keep the outer edges on the display bounds.
        func offset(_ index: Int, of divisions: Int, along length: CGFloat) -> CGFloat {
            index == divisions ? length : (length * CGFloat(index) / CGFloat(divisions)).rounded()
        }

        return windowSet.windows.enumerated().map { index, window in
            let row = index / columns
            let column = index % columns
            let rowWidth = min(columns, count - row * columns)
            let left = offset(column, of: rowWidth, along: bounds.width)
            let right = offset(column + 1, of: rowWidth, along: bounds.width)
            let top = offset(row, of: rows, along: bounds.height)
            let bottom = offset(row + 1, of: rows, along: bounds.height)
            let frame = CGRect(x: bounds.minX + left, y: bounds.minY + top, width: right - left, height: bottom - top)
            let assignment = FrameAssignment<Window>(frame: frame, window: window, screenFrame: bounds,
                resizeRules: ResizeRules(isMain: true, unconstrainedDimension: .horizontal, scaleFactor: 1))
            return FrameAssignmentOperation(frameAssignment: assignment, windowSet: windowSet)
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
