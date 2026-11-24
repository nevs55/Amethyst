//
//  Windows.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 9/15/19.
//  Copyright Â© 2019 Ian Ynda-Hummel. All rights reserved.
//

import Foundation
import Silica

final class TrackedWindows<Window: WindowType> {
    typealias Screen = Window.Screen

    private(set) var windows: [Window] = []
    private var windowsByID: [Window.WindowID: Window] = [:]
    private(set) var lastMainWindows: [CGSSpaceID: Window] = [:]
    private var activeIDCache: Set<CGWindowID> = Set()
    private var deactivatedPIDs: Set<pid_t> = Set()
    private struct FloatingState {
        var baseFloating = false
        var excludedByRule = false
        var isFloating: Bool { baseFloating || excludedByRule }
        // A manual choice follows this window through minimization until it closes.
        var overrideOwner: pid_t?
    }
    private var floatingMap: [Window.WindowID: FloatingState] = [:]
    private struct Pin {
        let owner: pid_t
        let frame: CGRect
        let display: CGRect

        func frame(on bounds: CGRect) -> CGRect {
            guard bounds != display else { return frame }
            return CGRect(x: bounds.minX + (frame.minX - display.minX) * bounds.width / display.width,
                          y: bounds.minY + (frame.minY - display.minY) * bounds.height / display.height,
                          width: frame.width * bounds.width / display.width,
                          height: frame.height * bounds.height / display.height).integral
        }
    }
    private var pins: [Window.WindowID: Pin] = [:]
    private let onScreenIDs: () -> Set<CGWindowID>?
    private let spaceForWindow: (Window) -> Int?

    init(onScreenIDs: @escaping () -> Set<CGWindowID>? = CGWindowsInfo<Window>.onScreenIDs,
         spaceForWindow: @escaping (Window) -> Int? = CGWindowsInfo<Window>.windowSpace) {
        self.onScreenIDs = onScreenIDs
        self.spaceForWindow = spaceForWindow
    }

    // MARK: Window Filters

    func window(withID id: Window.WindowID) -> Window? {
        return windowsByID[id]
    }

    func windows(forApplicationWithPID applicationPID: pid_t) -> [Window] {
        return windows.filter { $0.pid() == applicationPID }
    }

    func windows(onScreen screen: Screen) -> [Window] {
        return windows.filter { $0.screen() == screen }
    }

    func activeWindows(onScreen screen: Screen) -> [Window] {
        guard let screenID = screen.screenID() else {
            return []
        }

        guard let currentSpace = CGSpacesInfo<Window>.currentSpaceForScreen(screen) else {
            log.warning("Could not find a space for screen: \(screenID)")
            return []
        }

        let screenWindows = windows.filter { window in
            let space = spaceForWindow(window)

            guard let windowScreen = window.screen(), currentSpace.id == space else {
                return false
            }

            let isActive = self.isWindowActive(window)
            let isHidden = self.isWindowHidden(window)
            let isFloating = self.isWindowFloating(window)

            return windowScreen.screenID() == screen.screenID() && isActive && !isHidden && !isFloating
        }

        return screenWindows
    }

    func activeWindowOnCurrentScreen(atIndex: Int) -> Window? {
        guard let focusedWindow = Window.currentlyFocused(),
              let currentScreen = focusedWindow.screen() else {
            return nil
        }
        let activeWindows = activeWindows(onScreen: currentScreen)

        return activeWindows.indices.contains(atIndex) ? activeWindows[atIndex] : nil
    }

    // MARK: Adding and Removing

    func add(window: Window, atFront shouldInsertAtFront: Bool) {
        let id = window.id()
        guard windowsByID[id] == nil else { return }
        windowsByID[id] = window
        if shouldInsertAtFront {
            if let currentFocusedSpace = CGSpacesInfo<Window>.currentFocusedSpace(),
               let firstActiveWindow = activeWindowOnCurrentScreen(atIndex: 0) {
                rememberMainWindow(firstActiveWindow, on: currentFocusedSpace.id)
            }

            windows.insert(window, at: 0)
        } else {
            windows.append(window)
        }
    }

    func add(window: Window, afterWindow otherWindow: Window) -> Bool {
        let id = window.id()
        guard windowsByID[id] == nil, let otherWindowIndex = windows.firstIndex(of: otherWindow) else {
            return false
        }

        windows.insert(window, at: otherWindowIndex)
        windowsByID[id] = window

        return true
    }

    func rememberMainWindow(_ window: Window, on spaceID: CGSSpaceID) {
        lastMainWindows[spaceID] = window
    }

    func remove(window: Window, minimized: Bool = false) {
        let id = window.id()
        if !minimized { pins.removeValue(forKey: id) }
        if !minimized || floatingMap[id]?.overrideOwner == nil {
            floatingMap.removeValue(forKey: id)
        }
        lastMainWindows = lastMainWindows.filter { $0.value.id() != id }

        guard let tracked = windowsByID.removeValue(forKey: id), let windowIndex = windows.firstIndex(of: tracked) else {
            return
        }

        windows.remove(at: windowIndex)
    }

    /**
     Swaps the stored instance of an already-tracked window for `window`, which has
     the same identity but a fresh AX element. Order and floating state are untouched.
     See `WindowManager.refreshTrackedWindow` for why elements go stale.

     - Returns: The replaced instance, or `nil` if the window is untracked or already
     stored as this exact element.
     */
    func refreshWindow(_ window: Window) -> Window? {
        let id = window.id()
        guard let staleWindow = windowsByID[id], staleWindow != window,
              let index = windows.firstIndex(of: staleWindow) else {
            return nil
        }

        windowsByID[id] = window
        windows[index] = window
        return staleWindow
    }

    /// Replaces `window` in the tracking order with `otherWindow`, dropping `window`.
    @discardableResult func replace(window: Window, withWindow otherWindow: Window) -> Bool {
        if let currentFocusedSpace = CGSpacesInfo<Window>.currentFocusedSpace(),
           let firstActiveWindow = activeWindowOnCurrentScreen(atIndex: 0) {
            if firstActiveWindow == window || firstActiveWindow == otherWindow {
                rememberMainWindow(firstActiveWindow, on: currentFocusedSpace.id)
            }
        }

        let id = window.id()
        let otherID = otherWindow.id()
        guard let tracked = windowsByID[id], let windowIndex = windows.firstIndex(of: tracked) else {
            if !isWindowTracked(otherWindow) { add(window: otherWindow, atFront: false) }
            return false
        }
        let otherWindowIndex = windowsByID[otherID].flatMap { windows.firstIndex(of: $0) }
        windows[windowIndex] = otherWindow
        windowsByID.removeValue(forKey: id)
        windowsByID[otherID] = otherWindow

        if let otherWindowIndex, otherWindowIndex != windowIndex {
            windows.remove(at: otherWindowIndex)
        }

        return true
    }

    @discardableResult func swap(window: Window, withWindow otherWindow: Window) -> Bool {
        if let currentFocusedSpace = CGSpacesInfo<Window>.currentFocusedSpace(),
           let firstActiveWindow = activeWindowOnCurrentScreen(atIndex: 0) {
            if firstActiveWindow.id() == window.id() || firstActiveWindow.id() == otherWindow.id() {
                rememberMainWindow(firstActiveWindow, on: currentFocusedSpace.id)
            }
        }

        if windows.firstIndex(of: window) == nil {
            add(window: window, atFront: false)
        }

        guard let windowIndex = windows.firstIndex(of: window), let otherWindowIndex = windows.firstIndex(of: otherWindow) else {
            return false
        }

        guard windowIndex != otherWindowIndex else {
            return false
        }

        windows.swapAt(windowIndex, otherWindowIndex)

        return true
    }

    // MARK: Window States

    func isWindowTracked(_ window: Window) -> Bool {
        return windowsByID[window.id()] != nil
    }

    func isPinned(_ id: Window.WindowID) -> Bool { pins[id] != nil }

    func setPinned(_ pinned: Bool, forID id: Window.WindowID) -> Bool {
        guard let window = windowsByID[id], isPinned(id) != pinned else { return false }
        if pinned {
            guard !isWindowFloating(window), let screen = window.screen() else { return false }
            let bounds = screen.frameIncludingDockAndMenu()
            let frame = window.frame()
            guard !bounds.isEmpty, !frame.isEmpty, !frame.isInfinite, bounds.intersects(frame) else { return false }
            pins[id] = Pin(owner: window.pid(), frame: frame, display: bounds)
        } else {
            pins.removeValue(forKey: id)
        }
        return true
    }

    func floatingState(forTrackedID id: Window.WindowID) -> Bool? {
        guard windowsByID[id] != nil else { return nil }
        return floatingMap[id]?.isFloating ?? false
    }

    func isWindowActive(_ window: Window) -> Bool {
        return window.isActive() && activeIDCache.contains(window.cgID())
    }

    func isWindowHidden(_ window: Window) -> Bool {
        return deactivatedPIDs.contains(window.pid())
    }

    func isWindowFloating(_ window: Window) -> Bool {
        return floatingMap[window.id()]?.isFloating ?? false
    }

    func setFloating(_ floating: Bool, forWindow window: Window) {
        let id = window.id()
        guard floatingMap[id]?.overrideOwner == nil else { return }
        floatingMap[id, default: FloatingState()].baseFloating = floating
    }

    /// Returns whether the effective floating state changed and the layout needs updating.
    @discardableResult func applySavedExclusion(_ excluded: Bool, to window: Window) -> Bool {
        let id = window.id()
        var state = floatingMap[id] ?? FloatingState()
        guard state.excludedByRule != excluded else { return false }
        let wasFloating = state.isFloating
        state.excludedByRule = excluded
        if excluded { pins.removeValue(forKey: id) }
        floatingMap[id] = state
        return wasFloating != state.isFloating
    }

    func setFloatingOverride(_ floating: Bool, forID id: Window.WindowID) -> Window? {
        guard let window = window(withID: id), floatingMap[id]?.excludedByRule != true,
              isWindowFloating(window) != floating else { return nil }
        floatingMap[id] = FloatingState(baseFloating: floating, overrideOwner: window.pid())
        if floating { pins.removeValue(forKey: id) }
        return window
    }

    func clearFloatingOverrides(forPID pid: pid_t) {
        floatingMap = floatingMap.filter { $0.value.overrideOwner != pid }
        pins = pins.filter { $0.value.owner != pid }
    }

    func activateApplication(withPID pid: pid_t) {
        deactivatedPIDs.remove(pid)
    }

    func deactivateApplication(withPID pid: pid_t) {
        deactivatedPIDs.insert(pid)
    }

    func regenerateActiveIDCache() {
        if let ids = onScreenIDs() {
            activeIDCache = ids
        }
    }

    // MARK: Window Sets

    func windowSet(forWindowsOnScreen screen: Screen) -> WindowSet<Window> {
        return windowSet(forWindows: windows(onScreen: screen))
    }

    func windowSet(forActiveWindowsOnScreen screen: Screen) -> WindowSet<Window> {
        // A close can change the visible set before the AX destroy notification arrives.
        regenerateActiveIDCache()
        return windowSet(forWindows: activeWindows(onScreen: screen))
    }

    func windowSet(forWindows windows: [Window]) -> WindowSet<Window> {
        let layoutWindows: [LayoutWindow<Window>] = windows.map { window in
            let id = window.id()
            let pinnedFrame = pins[id].flatMap { pin in window.screen().map { pin.frame(on: $0.frameIncludingDockAndMenu()) } }
            return LayoutWindow(id: id, frame: window.frame(), isFocused: window.isFocused(), pinnedFrame: pinnedFrame)
        }

        let snapshotFloatingMap = floatingMap
        let snapshotActiveIDCache = activeIDCache
        let snapshotWindowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id(), $0) })

        return WindowSet<Window>(
            windows: layoutWindows,
            isWindowWithIDActive: { id -> Bool in
                guard let window = snapshotWindowsByID[id] else {
                    return false
                }
                return window.isActive() && snapshotActiveIDCache.contains(window.cgID())
            },
            isWindowWithIDFloating: { windowID -> Bool in
                return snapshotFloatingMap[windowID]?.isFloating ?? false
            },
            windowForID: { windowID -> Window? in
                return snapshotWindowsByID[windowID]
            }
        )
    }
}
