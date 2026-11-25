import Foundation

/// A reusable template contains only a name and rectangles in unit display coordinates.
struct SavedDesktop: Codable, Equatable {
    let id: UUID
    let name: String
    let slots: [CGRect]

    var key: String { "saved-desktop-" + id.uuidString }

    init?(name: String, frames: [CGRect], in bounds: CGRect, id: UUID = UUID()) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !bounds.isEmpty, !bounds.isInfinite else { return nil }
        let slots = frames.compactMap { frame -> CGRect? in
            guard !frame.isInfinite else { return nil }
            let visible = frame.intersection(bounds)
            guard !visible.isEmpty else { return nil }
            return CGRect(x: (visible.minX - bounds.minX) / bounds.width, y: (visible.minY - bounds.minY) / bounds.height,
                          width: visible.width / bounds.width, height: visible.height / bounds.height)
        }
        guard !slots.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.slots = slots
    }

    func frames(in bounds: CGRect) -> [CGRect] {
        slots.map { slot in
            let left = (slot.minX * bounds.width).rounded()
            let top = (slot.minY * bounds.height).rounded()
            let right = (slot.maxX * bounds.width).rounded()
            let bottom = (slot.maxY * bounds.height).rounded()
            return CGRect(x: bounds.minX + left, y: bounds.minY + top, width: right - left, height: bottom - top)
        }
    }
}

final class SavedDesktopLayout<Window: WindowType>: GridLayout<Window> {
    let template: SavedDesktop
    override var layoutKey: String { template.key }
    override var layoutName: String { template.name }
    // Captured window frames already include any spacing the user wanted.
    override var disableWindowMargins: Bool { true }

    init(_ template: SavedDesktop) {
        self.template = template
        super.init()
    }

    required init() { fatalError("A saved layout requires a template") }

    required init(from decoder: Decoder) throws {
        template = try SavedDesktop(from: decoder)
        super.init()
    }

    override func encode(to encoder: Encoder) throws {
        try template.encode(to: encoder)
    }

    override func tileFrames(count: Int, in bounds: CGRect) -> [CGRect] {
        let frames = template.frames(in: bounds)
        guard count > frames.count, let last = frames.last else { return Array(frames.prefix(count)) }
        let overflow = count - frames.count + 1
        return Array(frames.dropLast()) + gridFrames(count: overflow, columns: columnCount(for: overflow), in: last)
    }
}
