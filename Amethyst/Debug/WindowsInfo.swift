//
//  WindowsInfo.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 3/5/23.
//  Copyright Ã‚Â© 2023 Ian Ynda-Hummel. All rights reserved.
//

import ArgumentParser
import Cocoa
import Foundation
import Silica

extension AXWindow {
    func debugInfo(redactTitles: Bool) -> String {
        let screenDescription = screen().map { AMScreen(screen: $0).debugDescription() }

        return """
        \tTitle: \(redactTitles ? "<redacted>" : title() ?? "<no title>")
        \tFrame: \(frame())
        \tid: \(windowID())
        \(screenDescription ?? "Screen: unknown")
        \tisActive: \(isActive())
        \tisOnScreen: \(isOnScreen())
        \tisFocused: \(isFocused())
        \tshouldBeManaged: \(shouldBeManaged())
        \tshouldFloat: \(shouldFloat())
        """
    }
}

struct Windows: ParsableCommand {
    @Flag(help: "Include windows of unmanaged applications.")
    var includeUnmanaged = false

    @Flag(help: "Redact window titles.")
    var redactWindowTitles = false

    static func windowReport<Element>(for elements: [Element], describe: (Element) -> String?) -> String {
        return elements.map { element in
            describe(element) ?? "\tSkipped unreadable window (Accessibility role unavailable or not AXWindow)."
        }.joined(separator: "\n\n")
    }

    mutating func run() throws {
        print("Accessibility access for this diagnostic: \(AXIsProcessTrusted() ? "granted" : "not granted")")
        let applications = NSWorkspace.shared.runningApplications
        for application in applications where includeUnmanaged || application.isManageable == .manageable {
            let app = SIApplication(runningApplication: application)
            print("\(app.title() ?? "<no title>") (pid \(app.pid()))")
            let elements: [SIWindow] = app.windows()
            print(Self.windowReport(for: elements) { element in
                AXWindow(element: element)?.debugInfo(redactTitles: redactWindowTitles)
            })
        }
    }
}
