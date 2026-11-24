//
//  ScreenManagerTests.swift
//  AmethystTests
//
//  Created by Ian Ynda-Hummel on 2/11/20.
//  Copyright © 2020 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import Nimble
import Quick
import Silica
import SwiftyJSON
import XCTest

private final class PermissionTestAppDelegate: AppDelegate {
    var starts = 0
    override func startWindowManagement() { starts += 1 }
}

private final class TestDelegate: ScreenManagerDelegate {
    typealias Window = TestWindow

    func applyWindowLimit(forScreenManager screenManager: ScreenManager<TestDelegate>, minimizingIn range: (Int) -> Range<Int>) {
        fatalError()
    }
    func activeWindowSet(forScreenManager screenManager: ScreenManager<TestDelegate>, on screen: TestScreen) -> WindowSet<TestWindow> {
        fatalError()
    }
    func onReflowInitiation() {
        fatalError()
    }
    func onReflowCompletion() {
        fatalError()
    }
}

class ScreenManagerTests: QuickSpec {
    override func spec() {
        describe("per-display default layouts") {
            let first = Space(id: 1, type: CGSSpaceTypeUser, uuid: "first")
            let second = Space(id: 2, type: CGSSpaceTypeUser, uuid: "second")

            it("preserves explicit choices on reconnect and starts new Spaces with that monitor's default") {
                let config = UserConfiguration(storage: TestConfigurationStorage())
                config.setLayoutKeys(["tall", "widescreen-tall", "floating"])
                let screen = TestScreen(frame: .zero, id: "external")
                let manager = ScreenManager(screen: screen, delegate: TestDelegate(), userConfiguration: config)
                manager.updateSpace(to: first)
                manager.selectLayout("widescreen-tall")
                manager.useCurrentLayoutAsDisplayDefault()
                manager.selectLayout("floating")

                manager.updateScreen(to: TestScreen(frame: .zero, id: "external"))
                manager.updateSpace(to: first)
                expect(manager.currentLayout?.layoutKey).to(equal("floating"))
                manager.updateSpace(to: second)
                expect(manager.currentLayout?.layoutKey).to(equal("widescreen-tall"))
            }

            it("keeps independent defaults across manager and configuration recreation") {
                let storage = TestConfigurationStorage()
                let config = UserConfiguration(storage: storage)
                config.setLayoutKeys(["tall", "wide", "fullscreen"])
                for (display, key) in [("external", "wide"), ("built-in", "fullscreen")] {
                    let screen = TestScreen(frame: .zero, id: display)
                    let manager = ScreenManager(screen: screen, delegate: TestDelegate(), userConfiguration: config)
                    manager.updateSpace(to: first)
                    manager.selectLayout(key)
                    manager.useCurrentLayoutAsDisplayDefault()
                }

                let reloaded = UserConfiguration(storage: storage)
                reloaded.setLayoutKeys(["fullscreen", "tall", "wide"])
                for (display, expected) in [("external", "wide"), ("built-in", "fullscreen"), ("new", "fullscreen")] {
                    let screen = TestScreen(frame: .zero, id: display)
                    let manager = ScreenManager(screen: screen, delegate: TestDelegate(), userConfiguration: reloaded)
                    manager.updateSpace(to: second)
                    expect(manager.currentLayout?.layoutKey).to(equal(expected))
                }
            }

            it("falls back when a default is disabled and handles an empty layout list") {
                let config = UserConfiguration(storage: TestConfigurationStorage())
                let screen = TestScreen(frame: .zero, id: "external")
                config.setDefaultLayoutKey("wide", forDisplay: "external")
                config.setLayoutKeys(["floating", "tall"])
                let manager = ScreenManager(screen: screen, delegate: TestDelegate(), userConfiguration: config)
                manager.updateSpace(to: first)
                expect(manager.currentLayout?.layoutKey).to(equal("floating"))
                config.setLayoutKeys([])
                manager.updateSpace(to: second)
                expect(manager.currentLayout).to(beNil())
                manager.useCurrentLayoutAsDisplayDefault()
                expect(config.defaultLayoutKey(forDisplay: "external")).to(equal("wide"))
            }

            it("applies a changed default when revisiting a Space without an explicit choice") {
                let config = UserConfiguration(storage: TestConfigurationStorage())
                config.setLayoutKeys(["tall", "wide"])
                let manager = ScreenManager(screen: TestScreen(), delegate: TestDelegate(), userConfiguration: config)
                manager.updateSpace(to: first)
                expect(manager.currentLayout?.layoutKey).to(equal("tall"))
                manager.updateSpace(to: second)
                manager.selectLayout("wide")
                manager.useCurrentLayoutAsDisplayDefault()
                manager.updateSpace(to: first)
                expect(manager.currentLayout?.layoutKey).to(equal("wide"))
            }
        }

        describe("cycling layouts") {
            it("leaves the layout empty when both cycle commands are used") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys([])
                let manager = ScreenManager(screen: TestScreen(), delegate: TestDelegate(), userConfiguration: configuration)
                manager.cycleLayoutForward()
                manager.cycleLayoutBackward()
                expect(manager.currentLayout).to(beNil())
            }
        }

        it("looks up coincident same-app windows by their Core Graphics number") {
            let first = TestWindow(element: nil)!
            let second = TestWindow(element: nil)!
            first.cgWindowID = 101
            second.cgWindowID = 102
            for window in [first, second] {
                let description = [kCGWindowNumber as String: NSNumber(value: window.cgID())]
                expect(WindowsInformation.windowInWindows([first, second], withCGWindowDescription: description)).to(equal(window))
            }
        }

        it("delivers moves to the destination Space even while another Space is active") {
            let configuration = UserConfiguration(storage: TestConfigurationStorage())
            configuration.setLayoutKeys(["bsp"])
            let manager = ScreenManager(screen: TestScreen(), delegate: TestDelegate(), userConfiguration: configuration)
            let first = Space(id: 1, type: CGSSpaceTypeUser, uuid: "first")
            let second = Space(id: 2, type: CGSSpaceTypeUser, uuid: "second")
            let firstWindow = TestWindow(element: nil)!
            let secondWindow = TestWindow(element: nil)!
            let savedFocus = TestWindow.focused
            defer { TestWindow.focused = savedFocus }

            manager.updateSpace(to: first)
            manager.distributeEvent(.add(window: firstWindow), to: first)
            manager.distributeEvent(.add(window: secondWindow), to: second)
            expect(manager.lastFocusedWindow).to(equal(firstWindow))
            TestWindow.focused = firstWindow
            expect(manager.nextWindowIDClockwise()).to(equal(firstWindow.id()))
            manager.updateSpace(to: second)
            expect(manager.nextWindowIDClockwise()).to(beNil())
            TestWindow.focused = secondWindow
            expect(manager.nextWindowIDClockwise()).to(equal(secondWindow.id()))
        }

        it("restores each Space's selected layout after configuration reordering") {
            let configuration = UserConfiguration(storage: TestConfigurationStorage())
            configuration.setLayoutKeys(["tall", "wide", "fullscreen"])
            let manager = ScreenManager(screen: TestScreen(), delegate: TestDelegate(), userConfiguration: configuration)
            let first = Space(id: 1, type: CGSSpaceTypeUser, uuid: "first")
            let second = Space(id: 2, type: CGSSpaceTypeUser, uuid: "second")
            manager.updateSpace(to: first)
            manager.selectLayout("wide")
            manager.updateSpace(to: second)
            manager.selectLayout("fullscreen")
            let data = try JSONEncoder().encode(manager)

            let saved = UserDefaults.standard.object(forKey: ConfigurationKey.layouts.rawValue)
            defer { UserDefaults.standard.set(saved, forKey: ConfigurationKey.layouts.rawValue) }
            UserConfiguration.shared.setLayoutKeys(["fullscreen", "tall", "wide"])
            let restored = try JSONDecoder().decode(ScreenManager<TestDelegate>.self, from: data)
            restored.updateSpace(to: first)
            expect(restored.currentLayout?.layoutKey).to(equal("wide"))
            restored.updateSpace(to: second)
            expect(restored.currentLayout?.layoutKey).to(equal("fullscreen"))

            var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            legacy.removeValue(forKey: "selectionsBySpaceUUID")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            let old = try JSONDecoder().decode(ScreenManager<TestDelegate>.self, from: legacyData)
            old.updateSpace(to: first)
            expect(old.currentLayout?.layoutKey).to(equal("fullscreen"))
        }

        describe("window tracking") {
            it("starts observing even when the process-wide permission check returns false") {
                let app = PermissionTestAppDelegate()
                let config = UserConfiguration(storage: TestConfigurationStorage())
                config.delegate = app
                config.refreshAccessibilityPermissions { false }
                config.refreshAccessibilityPermissions { false }
                expect(app.starts).to(equal(1))
            }

            it("forgets destroyed windows even after tab replacement") {
                let windows = TrackedWindows<TestWindow>()
                let closing = TestWindow(element: nil)!
                let remaining = TestWindow(element: nil)!
                windows.add(window: closing, atFront: false)
                windows.setFloating(true, forWindow: closing)
                windows.replace(window: closing, withWindow: remaining)
                windows.rememberMainWindow(closing, on: 1)
                windows.rememberMainWindow(remaining, on: 2)
                windows.rememberMainWindow(closing, on: 3)

                windows.remove(window: closing)

                expect(windows.lastMainWindows[1]).to(beNil())
                expect(windows.lastMainWindows[2]).to(equal(remaining))
                expect(windows.lastMainWindows[3]).to(beNil())
                expect(windows.isWindowFloating(closing)).to(beFalse())
                expect(windows.isWindowTracked(remaining)).to(beTrue())
            }
        }

        describe("coding") {
            it("decodes layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys(LayoutType<TestWindow>.standardLayoutClasses().map { $0.layoutKey })

                let layouts = LayoutType<TestWindow>.standardLayoutClasses().map { $0.init() }
                let encoder = JSONEncoder()
                let encodedLayouts = layouts.map { ["key": $0.layoutKey.data(using: .utf8)!, "data": try! encoder.encode($0)] }
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect(decodedLayouts.count).to(equal(layouts.count))
                expect(decodedLayouts.count).to(equal(encodedLayouts.count))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(layouts.map { $0.layoutKey }))
            }

            it("replaces incorrectly encoded layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys([FullscreenLayout<TestWindow>.layoutKey, TallLayout<TestWindow>.layoutKey])

                let encoder = JSONEncoder()
                let encodedLayouts = [
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                    ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(["incorrect": "encoding"])]
                ]
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect {
                    try JSONDecoder().decode(TallLayout<TestWindow>.self, from: encodedLayouts[1]["data"]!)
                }.to(throwError())

                expect(decodedLayouts.count).to(equal(2))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
            }

            it("replaces incorrectly keyed layouts") {
                let configuration = UserConfiguration(storage: TestConfigurationStorage())
                configuration.setLayoutKeys([FullscreenLayout<TestWindow>.layoutKey, TallLayout<TestWindow>.layoutKey])

                let encoder = JSONEncoder()
                let encodedLayouts = [
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                    ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(TallLayout<TestWindow>())]
                ]
                let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                expect(decodedLayouts.count).to(equal(2))
                expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
            }

            context("layout list changes") {
                it("maintains encoded layouts on insertions") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        FullscreenLayout<TestWindow>.layoutKey,
                        WideLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains encoded layouts on appends") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        FullscreenLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey,
                        WideLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts[1] as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains encoded layouts on prepends") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        WideLayout<TestWindow>.layoutKey,
                        FullscreenLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let tallLayout = TallLayout<TestWindow>()
                    tallLayout.increaseMainPaneCount()

                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(3))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }

                it("maintains existing layouts on deletes") {
                    let configuration = UserConfiguration(storage: TestConfigurationStorage())
                    configuration.setLayoutKeys([
                        WideLayout<TestWindow>.layoutKey,
                        TallLayout<TestWindow>.layoutKey
                    ])

                    let encoder = JSONEncoder()
                    let wideLayout = WideLayout<TestWindow>()
                    let tallLayout = TallLayout<TestWindow>()
                    wideLayout.increaseMainPaneCount()
                    tallLayout.increaseMainPaneCount()

                    expect(wideLayout.mainPaneCount).to(equal(2))
                    expect(tallLayout.mainPaneCount).to(equal(2))

                    let encodedLayouts = [
                        ["key": WideLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(wideLayout)],
                        ["key": FullscreenLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(FullscreenLayout<TestWindow>())],
                        ["key": TallLayout<TestWindow>.layoutKey.data(using: .utf8)!, "data": try! encoder.encode(tallLayout)]
                    ]
                    let decodedLayouts = try! ScreenManager<TestDelegate>.decodedLayouts(from: encodedLayouts, userConfiguration: configuration)

                    expect(decodedLayouts.count).to(equal(2))
                    expect(decodedLayouts.map { $0.layoutKey }).to(equal(configuration.layoutKeys()))
                    expect((decodedLayouts.first as? WideLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                    expect((decodedLayouts.last as? TallLayout<TestWindow>)?.mainPaneCount).to(equal(2))
                }
            }
        }
    }
}

final class WindowTilingMenuTests: XCTestCase {
    @MainActor func testSlowWindowLookupLeavesMenuResponsiveAndCannotUpdateAReopenedMenu() async {
        let lookup = StatusMenuWindowLookup()
        let reading = expectation(description: "Background AX read started")
        let resumed = expectation(description: "Reopened menu received its own result")
        let release = DispatchSemaphore(value: 0)
        lookup.start(read: {
            XCTAssertFalse(Thread.isMainThread)
            reading.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return nil
        }, show: { _ in XCTFail("Closed menu received a stale result") })
        await fulfillment(of: [reading], timeout: 2)
        // Main-thread menu handling can close and reopen before the first app replies.
        lookup.cancel()
        lookup.start(read: { nil }, show: { _ in
            XCTAssertTrue(Thread.isMainThread)
            resumed.fulfill()
        })
        release.signal()
        await fulfillment(of: [resumed], timeout: 3)
    }

    func testMenuLooksUpOnlyCurrentlyTrackedWindowIDs() throws {
        let tracker = TrackedWindows<TestWindow>()
        let first = try XCTUnwrap(TestWindow(element: nil))
        let second = try XCTUnwrap(TestWindow(element: nil))
        let third = try XCTUnwrap(TestWindow(element: nil))
        tracker.add(window: first, atFront: false)
        XCTAssertTrue(tracker.add(window: second, afterWindow: first))
        XCTAssertTrue(tracker.swap(window: third, withWindow: first))
        XCTAssertEqual(tracker.floatingState(forTrackedID: third.id()), false)
        _ = tracker.setFloatingOverride(true, forID: second.id())
        XCTAssertEqual(tracker.floatingState(forTrackedID: second.id()), true)
        XCTAssertTrue(tracker.replace(window: first, withWindow: third))
        XCTAssertNil(tracker.floatingState(forTrackedID: first.id()))
        XCTAssertEqual(tracker.floatingState(forTrackedID: third.id()), false)
        tracker.remove(window: second, minimized: true)
        XCTAssertNil(tracker.floatingState(forTrackedID: second.id()))
        tracker.add(window: second, atFront: false)
        XCTAssertEqual(tracker.floatingState(forTrackedID: second.id()), true)
        tracker.remove(window: second)
        XCTAssertNil(tracker.window(withID: second.id()))
    }

    @MainActor func testSavedWindowMenuPersistsExactAppAndTitleAndCanRemoveItWithoutFocus() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        XCTAssertTrue(try XCTUnwrap(app.excludedWindowsMenu).supermenu === app.statusItemMenu)
        let domain = "AmethystTests.Exclusions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let config = UserConfiguration(storage: defaults)
        let menu = NSMenu()
        let rule = try XCTUnwrap(WindowExclusion(bundleIdentifier: "test.editor", title: "Plan [1].*"))
        let other = try XCTUnwrap(WindowExclusion(bundleIdentifier: "test.viewer", title: rule.title))
        func render(_ selected: WindowExclusion?, using configuration: UserConfiguration) {
            app.updateExcludedWindowsMenu(menu, selected: selected, rules: configuration.savedWindowExclusions) { rule, enabled in
                configuration.setWindowExclusion(rule, enabled: enabled)
            }
        }
        func click(_ item: NSMenuItem) throws {
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        render(rule, using: config)
        XCTAssertEqual(menu.items.last?.title, "No Saved Exclusions")
        let save = try XCTUnwrap(menu.item(at: 0))
        XCTAssertEqual(save.title, "Always Exclude “Plan [1].*”")
        try click(save)
        try click(save)
        let reopened = UserConfiguration(storage: try XCTUnwrap(UserDefaults(suiteName: domain)))
        reopened.loadConfiguration()
        XCTAssertEqual(reopened.savedWindowExclusions, [rule])
        XCTAssertTrue(reopened.excludesWindow(in: rule.bundleIdentifier, title: rule.title))
        XCTAssertFalse(reopened.excludesWindow(in: other.bundleIdentifier, title: rule.title))
        XCTAssertFalse(reopened.excludesWindow(in: rule.bundleIdentifier, title: "Plan 1 draft"))
        XCTAssertFalse(reopened.excludesWindow(in: rule.bundleIdentifier, title: rule.title + " copy"))
        XCTAssertFalse(reopened.excludesWindow(in: rule.bundleIdentifier, title: nil))
        XCTAssertNil(WindowExclusion(bundleIdentifier: rule.bundleIdentifier, title: " \n "))
        XCTAssertNil(WindowExclusion(bundleIdentifier: nil, title: rule.title))
        render(rule, using: reopened)
        XCTAssertFalse(try XCTUnwrap(menu.item(at: 0)).isEnabled)
        render(other, using: reopened)
        try click(try XCTUnwrap(menu.item(at: 0)))
        render(nil, using: reopened)
        XCTAssertFalse(try XCTUnwrap(menu.item(at: 0)).isEnabled)
        try click(try XCTUnwrap(menu.item(withTitle: "Remove “Plan [1].*” (test.editor)")))
        XCTAssertEqual(config.savedWindowExclusions, [other])
        XCTAssertFalse(config.hasWindowExclusions(in: rule.bundleIdentifier))
    }

    func testSavedExclusionAppliesToReopenedWindowAndPreservesOtherFloatingChoices() throws {
        let config = UserConfiguration(storage: TestConfigurationStorage())
        let rule = try XCTUnwrap(WindowExclusion(bundleIdentifier: "test.editor", title: "Document"))
        config.setWindowExclusion(rule, enabled: true)
        let tracker = TrackedWindows<TestWindow>()
        let original = try XCTUnwrap(TestWindow(element: nil))
        tracker.add(window: original, atFront: false)
        XCTAssertTrue(tracker.applySavedExclusion(config.excludesWindow(in: rule.bundleIdentifier, title: rule.title), to: original))
        tracker.remove(window: original)
        let reopened = try XCTUnwrap(TestWindow(element: nil))
        tracker.add(window: reopened, atFront: false)
        XCTAssertNotEqual(original.id(), reopened.id())
        XCTAssertFalse(tracker.applySavedExclusion(config.excludesWindow(in: rule.bundleIdentifier, title: ""), to: reopened))
        XCTAssertTrue(tracker.applySavedExclusion(config.excludesWindow(in: rule.bundleIdentifier, title: rule.title), to: reopened))
        let snapshot = tracker.windowSet(forWindows: [reopened])
        XCTAssertTrue(snapshot.isWindowFloating(try XCTUnwrap(snapshot.windows.first)))
        XCTAssertNil(tracker.setFloatingOverride(false, forID: reopened.id()))
        config.setWindowExclusion(rule, enabled: false)
        XCTAssertTrue(tracker.applySavedExclusion(config.excludesWindow(in: rule.bundleIdentifier, title: rule.title), to: reopened))
        XCTAssertFalse(tracker.isWindowFloating(reopened))
        tracker.setFloating(true, forWindow: reopened)
        XCTAssertFalse(tracker.applySavedExclusion(true, to: reopened))
        XCTAssertFalse(tracker.applySavedExclusion(false, to: reopened))
        XCTAssertTrue(tracker.isWindowFloating(reopened))
    }

    @MainActor func testMenuTargetsTheNamedWindowAndClearsAnUnavailableSelection() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = try XCTUnwrap(app.windowTilingMenuItem)
        XCTAssertTrue(item.menu === app.statusItemMenu)
        defer { app.configureWindowTilingMenuItem() }
        let tracker = TrackedWindows<TestWindow>()
        let selected = try XCTUnwrap(TestWindow(element: nil))
        let other = try XCTUnwrap(TestWindow(element: nil))
        [selected, other].forEach { tracker.add(window: $0, atFront: false) }
        let previousFocus = TestWindow.focused
        defer { TestWindow.focused = previousFocus }

        func showChoice(for window: TestWindow) {
            let id = window.id()
            let floating = tracker.isWindowFloating(window)
            app.configureWindowTilingMenuItem(windowName: "Document", floating: floating) {
                _ = tracker.setFloatingOverride(!floating, forID: id)
            }
        }
        showChoice(for: selected)
        TestWindow.focused = other
        XCTAssertEqual(item.title, "Temporarily Exclude “Document”")
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(tracker.isWindowFloating(selected))
        XCTAssertFalse(tracker.isWindowFloating(other))
        showChoice(for: selected)
        XCTAssertEqual(item.title, "Return “Document” to Tiling")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertFalse(tracker.isWindowFloating(selected))

        showChoice(for: selected)
        tracker.remove(window: selected)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertFalse(tracker.isWindowFloating(selected))
        XCTAssertFalse(tracker.isWindowFloating(other))
        app.configureWindowTilingMenuItem()
        XCTAssertNil(item.representedObject)
        XCTAssertNil(item.action)
        XCTAssertFalse(item.isEnabled)
    }

    func testExcludingAWindowRetilesItsSiblingsAndSurvivesMinimization() throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), id: "external")
        let previousDescriptions = TestScreen.descriptions
        defer { TestScreen.descriptions = previousDescriptions }
        TestScreen.descriptions = [JSON(["Display Identifier": "external", "Current Space": ["ManagedSpaceID": 1, "type": 0, "uuid": "space"]])]
        let tracker = TrackedWindows<TestWindow>(onScreenIDs: { [1, 2, 3] }, spaceForWindow: { _ in 1 })
        let windows = try (1...3).map { number in
            let window = try XCTUnwrap(TestWindow(element: nil))
            window.cgWindowID = CGWindowID(number)
            window.testScreen = screen
            tracker.add(window: window, atFront: false)
            return window
        }
        let excluded = windows[1]
        XCTAssertNotNil(tracker.setFloatingOverride(true, forID: excluded.id()))
        let set = tracker.windowSet(forActiveWindowsOnScreen: screen)
        XCTAssertEqual(set.windows.map(\.id), [windows[0].id(), windows[2].id()])
        let tiles = try XCTUnwrap(TallLayout<TestWindow>().frameAssignments(set, on: screen))
        XCTAssertEqual(tiles.last?.frameAssignment.frame, CGRect(x: 600, y: 0, width: 600, height: 800))
        tracker.remove(window: excluded, minimized: true)
        tracker.setFloating(false, forWindow: excluded)
        tracker.add(window: excluded, atFront: false)
        XCTAssertTrue(tracker.isWindowFloating(excluded))
        XCTAssertNotNil(tracker.setFloatingOverride(false, forID: excluded.id()))
        XCTAssertEqual(tracker.windowSet(forActiveWindowsOnScreen: screen).windows.count, 3)
        _ = tracker.setFloatingOverride(true, forID: excluded.id())
        tracker.remove(window: excluded)
        XCTAssertFalse(tracker.isWindowFloating(excluded))
    }
}

final class WindowPinTests: XCTestCase {
    func testPinKeepsItsCapturedFrameAcrossCloseAndLayoutChange() throws {
        let bounds = CGRect(x: -1200, y: 30, width: 1200, height: 900)
        let screen = TestScreen(frame: bounds)
        let tracker = TrackedWindows<TestWindow>()
        let windows = try (0..<4).map { _ -> TestWindow in
            let window = try XCTUnwrap(TestWindow(element: nil))
            window.testScreen = screen
            tracker.add(window: window, atFront: false)
            return window
        }
        let pinned = windows[0]
        let left = CGRect(x: -1200, y: 30, width: 600, height: 900)
        pinned.setFrame(left, withThreshold: .zero)
        XCTAssertTrue(tracker.setPinned(true, forID: pinned.id()))
        tracker.remove(window: windows[1])
        // A reflow restores the captured rectangle even if the app moved itself.
        pinned.setFrame(bounds, withThreshold: .zero)
        let set = tracker.windowSet(forWindows: tracker.windows)
        let tall = try XCTUnwrap(TallLayout<TestWindow>().resolvedAssignments(set, on: screen))
        XCTAssertEqual(tall.map { $0.frameAssignment.frame }, [
            left, CGRect(x: -600, y: 30, width: 600, height: 450), CGRect(x: -600, y: 480, width: 600, height: 450)
        ])
        let wide = try XCTUnwrap(WideLayout<TestWindow>().resolvedAssignments(set, on: screen))
        XCTAssertEqual(wide.count, 3)
        XCTAssertEqual(wide.first?.frameAssignment.finalFrame, left)
        for operation in wide.dropFirst() {
            XCTAssertTrue(left.intersection(operation.frameAssignment.frame).isEmpty)
            XCTAssertTrue(bounds.contains(operation.frameAssignment.frame))
        }
        tracker.remove(window: pinned, minimized: true)
        tracker.add(window: pinned, atFront: false)
        XCTAssertTrue(tracker.isPinned(pinned.id()))
        XCTAssertTrue(tracker.setPinned(false, forID: pinned.id()))
        let unpinned = tracker.windowSet(forWindows: tracker.windows)
        let normal = try XCTUnwrap(WideLayout<TestWindow>().frameAssignments(unpinned, on: screen))
        XCTAssertEqual(WideLayout<TestWindow>().resolvedAssignments(unpinned, on: screen)?.map { $0.frameAssignment.frame },
                       normal.map { $0.frameAssignment.frame })
        XCTAssertTrue(tracker.setPinned(true, forID: pinned.id()))
        tracker.remove(window: pinned)
        XCTAssertFalse(tracker.isPinned(pinned.id()))
    }

    func testMultiplePinsReserveOnlyTheirVisibleArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let left = CGRect(x: 0, y: 0, width: 300, height: 800)
        let corner = CGRect(x: 800, y: 0, width: 200, height: 400)
        let desired = (0..<4).map { CGRect(x: $0 * 250, y: 0, width: 250, height: 800) }
        let tiles = WindowPinPlacement.tiles(in: bounds, avoiding: [left, corner], preferred: desired)
        XCTAssertEqual(tiles.count, desired.count)
        for (index, tile) in tiles.enumerated() {
            XCTAssertFalse(tile.isEmpty)
            XCTAssertTrue(bounds.contains(tile))
            XCTAssertTrue(tile.intersection(left).isEmpty)
            XCTAssertTrue(tile.intersection(corner).isEmpty)
            XCTAssertTrue(tiles.prefix(index).allSatisfy { $0.intersection(tile).isEmpty })
        }
        XCTAssertEqual(WindowPinPlacement.tiles(in: bounds, avoiding: [bounds], preferred: desired), desired)
    }

    @MainActor func testPinMenuActionAndUnavailableSelection() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = try XCTUnwrap(app.windowPinMenuItem)
        defer { app.configurePinMenuItem() }
        var clicked = false
        app.configurePinMenuItem(windowName: "Discord", enabled: true) { clicked = true }
        XCTAssertEqual(item.title, "Pin “Discord” Here")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(clicked)
        app.configurePinMenuItem(windowName: "Discord", pinned: true, enabled: true) {}
        XCTAssertEqual(item.title, "Unpin “Discord”")
        app.configurePinMenuItem()
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
        XCTAssertNil(item.representedObject)
    }
}

final class StatusLayoutsMenuTests: XCTestCase {
    func testEqualTileLayoutsCoverOffsetDisplayAfterEachWindowCloses() throws {
        let bounds = CGRect(x: -900, y: 45, width: 901, height: 603)
        let screen = TestScreen(frame: bounds)
        let windows = try (0..<7).map { _ in try XCTUnwrap(TestWindow(element: nil)) }
        for key in ["builtin-grid", "builtin-equal-columns", "builtin-equal-rows"] {
            let layout = try XCTUnwrap(LayoutType<TestWindow>.layoutForKey(key))
            for count in 0...windows.count {
                let set = TrackedWindows<TestWindow>().windowSet(forWindows: Array(windows.prefix(count)))
                let frames = try XCTUnwrap(layout.frameAssignments(set, on: screen)).map { $0.frameAssignment.frame }
                XCTAssertEqual(frames.count, count)
                guard count > 0 else { continue }
                XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, bounds)
                XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height)
                for (index, frame) in frames.enumerated() {
                    XCTAssertFalse(frames.prefix(index).contains { $0.intersection(frame).width * $0.intersection(frame).height > 0 })
                }
                if key == "builtin-equal-columns" { XCTAssertTrue(frames.allSatisfy { $0.height == bounds.height }) }
                if key == "builtin-equal-rows" { XCTAssertTrue(frames.allSatisfy { $0.width == bounds.width }) }
                if key == "builtin-grid", count == 4 { XCTAssertEqual(Set(frames.map(\.minY)).count, 2) }
            }
        }
    }

    @MainActor func testLayoutsCanBeSelectedWithoutProcessWideTrust() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let windowManager = try XCTUnwrap(app.windowManager)
        let screen = try XCTUnwrap(NSScreen.main)
        let config = UserConfiguration.shared
        let originalKeys = config.layoutKeys()
        let originalTrust = config.hasAccessibilityPermissions
        defer {
            config.setLayoutKeys(originalKeys)
            config.refreshAccessibilityPermissions { originalTrust }
        }
        config.refreshAccessibilityPermissions { false }
        config.setLayoutKeys(["tall", "wide"])
        let manager = ScreenManager(screen: AMScreen(screen: screen), delegate: windowManager, userConfiguration: config)
        manager.updateSpace(to: Space(id: 1, type: CGSSpaceTypeUser, uuid: "menu-test"))
        let menu = NSMenu()
        app.updateLayoutsMenu(menu, for: manager)
        let wide = try XCTUnwrap(menu.item(withTitle: "Main Pane")?.submenu?.item(withTitle: "Wide"))
        XCTAssertTrue(wide.isEnabled)
        XCTAssertNotNil(wide.action)
        app.selectLayout(wide)
        XCTAssertEqual(manager.currentLayout?.layoutKey, "wide")
        config.refreshAccessibilityPermissions { true }
        XCTAssertTrue(windowManager === app.windowManager)
    }

    @MainActor func testShowMenuBarIconTakesEffectInTheRunningApp() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let item = try XCTUnwrap(app.statusItem)
        let key = ConfigurationKey.hideMenuBarIcon.rawValue
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }
        defaults.set(true, forKey: key)
        XCTAssertFalse(item.isVisible)
        defaults.set(false, forKey: key)
        XCTAssertTrue(item.isVisible)
    }

    @MainActor func testNibSubmenuRefreshesFromPreferences() throws {
        let app = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let root = try XCTUnwrap(app.statusItemMenu)
        let submenu = try XCTUnwrap(app.layoutsMenuItem?.submenu)
        XCTAssertTrue(root.delegate === app)
        XCTAssertTrue(submenu.delegate === app)

        let config = UserConfiguration.shared
        let original = config.layoutKeys()
        defer { config.setLayoutKeys(original) }
        config.setLayoutKeys(["wide", "tall", "wide"])
        root.delegate?.menuNeedsUpdate?(root)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        let choices = try XCTUnwrap(submenu.item(withTitle: "Main Pane")?.submenu).items
        XCTAssertEqual(choices.map(\.title), ["Wide", "Tall", "Wide"])
        XCTAssertEqual(choices.map(\.tag), [0, 1, 2])

        config.setLayoutKeys(["column"])
        submenu.delegate?.menuNeedsUpdate?(submenu)
        XCTAssertEqual(submenu.item(withTitle: "Columns and Rows")?.submenu?.items.map { $0.identifier?.rawValue }, ["column"])
    }

    @MainActor func testConfiguredChoicesAreVisibleBeforeWindowManagementStarts() {
        let app = AppDelegate()
        let item = NSMenuItem(title: "Layouts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        item.submenu = submenu
        app.layoutsMenuItem = item
        let config = UserConfiguration.shared
        let original = config.layoutKeys()
        defer { config.setLayoutKeys(original) }
        config.setLayoutKeys(["tall", "wide"])
        app.menuNeedsUpdate(submenu)
        let choices = submenu.item(withTitle: "Main Pane")?.submenu?.items ?? []
        XCTAssertEqual(choices.map(\.title), ["Tall", "Wide"])
        XCTAssertTrue(choices.allSatisfy { !$0.isEnabled && $0.action == nil })
        XCTAssertTrue(submenu.items.last?.title.hasPrefix("Waiting for") == true)
    }

    @MainActor func testMenuSelectsTheClickedOccurrenceAfterPreferencesChange() {
        let config = UserConfiguration(storage: TestConfigurationStorage())
        config.setLayoutKeys(["tall", "wide"])
        let manager = ScreenManager(screen: TestScreen(frame: .zero), delegate: TestDelegate(), userConfiguration: config)
        manager.updateSpace(to: Space(id: 1, type: CGSSpaceTypeUser, uuid: "first"))
        let tall = manager.currentLayout
        config.setLayoutKeys(["wide", "tall", "wide"])
        manager.reloadLayouts()
        manager.selectLayout(at: 1, matching: "tall")
        XCTAssertTrue(manager.currentLayout === tall)
        manager.selectLayout(at: 2, matching: "wide")
        XCTAssertEqual(manager.layoutsInfo.map(\.isSelected), [false, false, true])
        manager.selectLayout(at: 2, matching: "wide")
        manager.selectLayout(at: 0, matching: "tall")
        XCTAssertEqual(manager.layoutsInfo.map(\.isSelected), [false, false, true])
    }
}

private final class WindowCloseTestDelegate: ScreenManagerDelegate {
    typealias Window = TestWindow

    let tracker: TrackedWindows<TestWindow>
    var didReflow: (() -> Void)?

    init(tracker: TrackedWindows<TestWindow>) {
        self.tracker = tracker
    }

    func applyWindowLimit(forScreenManager screenManager: ScreenManager<WindowCloseTestDelegate>, minimizingIn range: (Int) -> Range<Int>) {}
    func activeWindowSet(forScreenManager screenManager: ScreenManager<WindowCloseTestDelegate>, on screen: TestScreen) -> WindowSet<TestWindow> {
        tracker.windowSet(forActiveWindowsOnScreen: screen)
    }
    func onReflowInitiation() {}
    func onReflowCompletion() { didReflow?() }
}

final class TallWindowCloseTests: XCTestCase {
    @MainActor func testClosingNativeWindowTriggersTallReflowWithoutAXOrMouseEvent() async throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 3840, height: 1600), id: "external")
        let previousDescriptions = TestScreen.descriptions
        defer { TestScreen.descriptions = previousDescriptions }
        TestScreen.descriptions = [JSON(["Display Identifier": "external", "Current Space": ["ManagedSpaceID": 1, "type": 0, "uuid": "space"]])]
        let nativeWindows = (0..<4).map { index in
            let window = NSWindow(contentRect: CGRect(x: 100 + index * 100, y: 100, width: 90, height: 90), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.orderFrontRegardless()
            window.display()
            return window
        }
        defer { nativeWindows.forEach { $0.orderOut(nil) } }
        let nativeIDs = Set(nativeWindows.map { CGWindowID($0.windowNumber) })
        let deadline = Date().addingTimeInterval(5)
        while !nativeIDs.isSubset(of: CGWindowsInfo<TestWindow>.onScreenIDs() ?? []), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let onScreen = try XCTUnwrap(CGWindowsInfo<TestWindow>.onScreenIDs())
        guard nativeIDs.isSubset(of: onScreen) else {
            XCTFail("WindowServer did not present the test windows. Expected \(nativeIDs), found \(onScreen)")
            return
        }
        let tracker = TrackedWindows<TestWindow>(spaceForWindow: { _ in 1 })
        let windows = try nativeWindows.map { panel in
            let window = try XCTUnwrap(TestWindow(element: nil))
            window.cgWindowID = CGWindowID(panel.windowNumber)
            window.testScreen = screen
            tracker.add(window: window, atFront: false)
            return window
        }
        let delegate = WindowCloseTestDelegate(tracker: tracker)
        let config = UserConfiguration(storage: TestConfigurationStorage())
        config.setLayoutKeys(["tall"])
        let manager = ScreenManager(screen: screen, delegate: delegate, userConfiguration: config)
        manager.updateSpace(to: Space(id: 1, type: CGSSpaceTypeUser, uuid: "space"))
        let initialLayout = expectation(description: "Four windows tiled")
        delegate.didReflow = { initialLayout.fulfill() }
        manager.setNeedsReflow()
        await fulfillment(of: [initialLayout], timeout: 5)
        XCTAssertEqual(windows[1].frame(), CGRect(x: 1920, y: 0, width: 1920, height: 533))

        // No AX observer is registered for these windows. Only the production timer can
        // request another reflow after close returns.
        let resized = expectation(description: "Closing the top tile resizes the two survivors")
        delegate.didReflow = { resized.fulfill() }
        let timer = ScreenManager.observeWindowClosures(on: { [manager] }, interval: 0.1)
        defer { timer.invalidate() }
        nativeWindows[1].close()
        await fulfillment(of: [resized], timeout: 5)
        XCTAssertEqual(windows[0].frame(), CGRect(x: 0, y: 0, width: 1920, height: 1600))
        XCTAssertEqual(windows[2].frame(), CGRect(x: 1920, y: 0, width: 1920, height: 800))
        XCTAssertEqual(windows[3].frame(), CGRect(x: 1920, y: 800, width: 1920, height: 800))
        XCTAssertEqual(tracker.windows.count, 4, "A window leaving the screen is not proof of destruction")

        let unnecessaryReflow = expectation(description: "Stable tiles keep their frames")
        unnecessaryReflow.isInverted = true
        delegate.didReflow = { unnecessaryReflow.fulfill() }
        let missingSnapshot = ScreenManager.observeWindowClosures(on: { [manager] }, interval: 0.05, visibleIDs: { nil })
        defer { missingSnapshot.invalidate() }
        let unrelatedPanel = NSPanel(contentRect: .init(x: 80, y: 80, width: 60, height: 60), styleMask: .borderless, backing: .buffered, defer: false)
        unrelatedPanel.orderFrontRegardless()
        unrelatedPanel.orderOut(nil)
        await fulfillment(of: [unnecessaryReflow], timeout: 0.4)
    }

    @MainActor func testClosingTopRightResizesRemainingWindowsBeforeDestroyNotification() async throws {
        let screen = TestScreen(frame: CGRect(x: 0, y: 0, width: 3840, height: 1600), id: "external")
        let previousDescriptions = TestScreen.descriptions
        defer { TestScreen.descriptions = previousDescriptions }
        TestScreen.descriptions = [JSON(["Display Identifier": "external", "Current Space": ["ManagedSpaceID": 1, "type": 0, "uuid": "space"]])]
        let windows = (1...4).map { id -> TestWindow in
            let window = TestWindow(element: nil)!
            window.cgWindowID = CGWindowID(id)
            window.testScreen = screen
            return window
        }
        var visible = Set(windows.map { $0.cgID() })
        let tracker = TrackedWindows<TestWindow>(onScreenIDs: { visible }, spaceForWindow: { _ in 1 })
        windows.forEach { tracker.add(window: $0, atFront: false) }
        let layout = TallLayout<TestWindow>()
        let original = tracker.windowSet(forActiveWindowsOnScreen: screen)
        let before = try XCTUnwrap(layout.frameAssignments(original, on: screen))
        XCTAssertEqual(before.count, 4)
        XCTAssertEqual(before.dropFirst().first?.frameAssignment.frame, CGRect(x: 1920, y: 0, width: 1920, height: 533))

        visible.remove(windows[1].cgID())
        let expected = [
            windows[0].id(): CGRect(x: 0, y: 0, width: 1920, height: 1600),
            windows[2].id(): CGRect(x: 1920, y: 0, width: 1920, height: 800),
            windows[3].id(): CGRect(x: 1920, y: 800, width: 1920, height: 800)
        ]
        let duringClose = tracker.windowSet(forActiveWindowsOnScreen: screen)
        let assignments = try XCTUnwrap(layout.frameAssignments(duringClose, on: screen))
        XCTAssertEqual(assignments.count, 3)
        let queue = OperationQueue()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            queue.addOperations(assignments, waitUntilFinished: false)
            queue.addBarrierBlock { finished.resume() }
        }
        for window in [windows[0], windows[2], windows[3]] {
            XCTAssertEqual(window.frame(), expected[window.id()])
        }
        XCTAssertEqual(windows[1].frame(), .zero)
        tracker.remove(window: windows[1])
        let afterClose = tracker.windowSet(forActiveWindowsOnScreen: screen)
        let after = try XCTUnwrap(layout.frameAssignments(afterClose, on: screen))
        XCTAssertEqual(after.count, 3)
        for operation in after {
            XCTAssertEqual(operation.frameAssignment.frame, expected[operation.frameAssignment.window.id])
        }
    }
}
