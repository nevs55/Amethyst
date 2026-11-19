@testable import Amethyst
import Cocoa
import Nimble
import Quick

class SIWindowAmethystTests: QuickSpec {
    override func spec() {
        it("reports readable windows before and after an unreadable Accessibility element") {
            let results: [String?] = ["first window", nil, "last window"]
            let report = Windows.windowReport(for: results) { $0 }
            expect(report.components(separatedBy: "\n\n")).to(equal([
                "first window", "\tSkipped unreadable window (Accessibility role unavailable or not AXWindow).", "last window"
            ]))
        }

        describe("approximate rect comparison") {
            it("tolerates some provided error") {
                let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
                let tolerance = CGRect(x: 10, y: 10, width: 10, height: 10)
                let translations = [
                    CGAffineTransform(translationX: 5, y: 5),
                    CGAffineTransform(translationX: 5, y: 0),
                    CGAffineTransform(translationX: 5, y: -5),
                    CGAffineTransform(translationX: 0, y: 5),
                    CGAffineTransform(translationX: 0, y: -5),
                    CGAffineTransform(translationX: -5, y: 5),
                    CGAffineTransform(translationX: -5, y: 0),
                    CGAffineTransform(translationX: -5, y: -5),

                    CGAffineTransform(scaleX: 1.05, y: 1.05),
                    CGAffineTransform(scaleX: 1.05, y: 0.95),
                    CGAffineTransform(scaleX: 0.95, y: 1.05),
                    CGAffineTransform(scaleX: 0.95, y: 0.95)
                ]

                translations.forEach {
                    expect(rect.applying($0).approximatelyEqual(to: rect, within: tolerance)).to(beTrue(), description: "\($0)")
                }
            }
        }
    }
}
