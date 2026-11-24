//
//  AppDelegate.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 5/8/16.
//  Copyright © 2016 Ian Ynda-Hummel. All rights reserved.
//

import CoreServices
import Foundation
import LoginServiceKit
import RxCocoa
import RxSwift
import Silica
import Sparkle
import SwiftyBeaver

/// Each opening owns its lookup. Closing a menu invalidates even an AX call already in flight.
final class StatusMenuWindowLookup {
    private let queue = OperationQueue()
    private var request: UUID?

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func start(read: @escaping () -> AXWindow.MenuSelection?, show: @escaping (AXWindow.MenuSelection?) -> Void) {
        cancel()
        let token = UUID()
        request = token
        queue.addOperation {
            let selection = read()
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard self?.request == token else { return }
                show(selection)
            }
        }
    }

    func cancel() {
        request = nil
        queue.cancelAllOperations()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static let windowManagerEncodingKey = "EncodedWindowManager"

    @IBOutlet var preferencesWindowController: PreferencesWindowController?

    private(set) var windowManager: WindowManager<SIApplication>?
    private var hotKeyManager: HotKeyManager<SIApplication>?
    private var permissionTimer: Timer?
    private let disposeBag = DisposeBag()
    private let permissionMenuItem = NSMenuItem(title: "Check Window Access…", action: #selector(AppDelegate.checkWindowAccess(_:)), keyEquivalent: "")

    private(set) var statusItem: NSStatusItem?
    private var layoutMenuScreen: NSScreen?
    private let menuWindowLookup = StatusMenuWindowLookup()
    private var menuSelectionResolved = false
    private var selectedMenuRule: WindowExclusion?
    private var showingExcludedWindows = false
    @IBOutlet var statusItemMenu: NSMenu?
    @IBOutlet var versionMenuItem: NSMenuItem?
    @IBOutlet var startAtLoginMenuItem: NSMenuItem?
    @IBOutlet var toggleGlobalTilingMenuItem: NSMenuItem?
    @IBOutlet var windowTilingMenuItem: NSMenuItem?
    @IBOutlet var excludedWindowsMenu: NSMenu?
    @IBOutlet var layoutsMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
            log.addDestination(ConsoleDestination())
        #endif

        if CommandLine.arguments.contains("--log") {
            let destination = ConsoleDestination()
            destination.useNSLog = true
            log.addDestination(destination)
        }

        log.info("Logging is enabled")
        log.debug("Debug logging is enabled")

        UserConfiguration.shared.load()
        UserConfiguration.shared.delegate = self
        UserConfiguration.shared.tilingEnabled = !UserConfiguration.shared.startWithTilingDisabled()

        #if RELEASE
            let appcastURLString: String? = {
                if UserConfiguration.shared.useCanaryBuild() {
                    return Bundle.main.infoDictionary?["SUCanaryFeedURL"] as? String
                } else {
                    return Bundle.main.infoDictionary?["SUFeedURL"] as? String
                }
            }()

            if let appcastURLString = appcastURLString, let url = URL(string: appcastURLString) {
                SUUpdater.shared().feedURL = url
            } else {
                log.error("Sparkle feed URL is missing or malformed in Info.plist")
            }
        #endif

        preferencesWindowController?.window?.level = .floating
        configurationAccessibilityPermissionsDidChange(UserConfiguration.shared)
        populateLayoutsMenu()
    }

    func startWindowManagement() {
        if let encodedWindowManager = UserDefaults.standard.data(forKey: AppDelegate.windowManagerEncodingKey), UserConfiguration.shared.restoreLayoutsOnLaunch() {
            let decoder = JSONDecoder()
            windowManager = try? decoder.decode(WindowManager<SIApplication>.self, from: encodedWindowManager)
        }

        let resolvedWindowManager = windowManager ?? WindowManager(userConfiguration: UserConfiguration.shared)
        windowManager = resolvedWindowManager
        hotKeyManager = HotKeyManager(userConfiguration: UserConfiguration.shared)

        hotKeyManager?.setUpWithWindowManager(resolvedWindowManager, configuration: UserConfiguration.shared, appDelegate: self)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        if Bundle.main.bundleIdentifier == "com.github.nevs55.AmethystPreview" {
            Self.importPreviewPreferences()
        }
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        let shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let statusItemImage = NSImage(named: "icon-statusitem")
        statusItemImage?.isTemplate = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.image = statusItemImage
        statusItem?.menu = statusItemMenu
        permissionMenuItem.target = self
        statusItemMenu?.insertItem(permissionMenuItem, at: 1)
        statusItem?.highlightMode = true

        UserDefaults.standard.rx.observe(Bool.self, ConfigurationKey.hideMenuBarIcon.rawValue)
            .distinctUntilChanged { $0 == $1 }
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.statusItem?.isVisible = !UserConfiguration.shared.hideMenuBarIcon()
            })
            .disposed(by: disposeBag)

        versionMenuItem?.title = "Version \(shortVersion) (\(version))"
        toggleGlobalTilingMenuItem?.title = "Disable"

        startAtLoginMenuItem?.state = (LoginServiceKit.isExistLoginItems(at: Bundle.main.bundlePath) ? .on : .off)

        if layoutsMenuItem?.submenu == nil {
            layoutsMenuItem?.submenu = NSMenu(title: "Layouts")
        }
        layoutsMenuItem?.submenu?.delegate = self
        excludedWindowsMenu?.delegate = self
        statusItemMenu?.delegate = self
    }

    private static func importPreviewPreferences() {
        let defaults = UserDefaults.standard
        let marker = "importedOriginalAmethystPreferences"
        guard !defaults.bool(forKey: marker) else { return }
        let original = defaults.persistentDomain(forName: "com.amethyst.Amethyst") ?? [:]
        for (key, value) in original where defaults.object(forKey: key) == nil {
            if ConfigurationKey(rawValue: key) != nil || CommandKey(rawValue: key) != nil ||
                key.hasPrefix("KeyboardShortcuts_") || key.hasPrefix("migrated-") ||
                key == windowManagerEncodingKey || key == "disable-dotfile-conflict-warning" {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }

    /// Opening Amethyst while it is already running, from the Finder, Spotlight or `open`, shows Preferences, since the app has no Dock icon or main window to come forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferencesWindow(self)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let windowManager = windowManager else {
            return
        }

        do {
            let encoder = JSONEncoder()
            let encodedWindowManager = try encoder.encode(windowManager)
            UserDefaults.standard.set(encodedWindowManager, forKey: AppDelegate.windowManagerEncodingKey)
        } catch {
            log.error("Failed to encode window manager: \(error)")
        }
    }

    @IBAction func toggleStartAtLogin(_ sender: AnyObject) {
        if startAtLoginMenuItem?.state == .off {
            LoginServiceKit.addLoginItems(at: Bundle.main.bundlePath)
        } else {
            LoginServiceKit.removeLoginItems(at: Bundle.main.bundlePath)
        }
        startAtLoginMenuItem?.state = (LoginServiceKit.isExistLoginItems(at: Bundle.main.bundlePath) ? .on : .off)
    }

    @IBAction func toggleGlobalTiling(_ sender: AnyObject) {
        UserConfiguration.shared.tilingEnabled = !UserConfiguration.shared.tilingEnabled
        windowManager?.markAllScreensForReflow()
    }

    private func updateWindowTilingMenu(selection: AXWindow.MenuSelection?, for application: NSRunningApplication?) {
        if let selection, let application, let manager = windowManager,
           let floating = manager.floatingState(forTrackedID: selection.id) {
            let id = selection.id
            selectedMenuRule = WindowExclusion(bundleIdentifier: application.bundleIdentifier, title: selection.title)
            let title = selection.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = title.isEmpty ? (application.localizedName ?? "Selected Window") : title
            configureWindowTilingMenuItem(windowName: name, floating: floating) { [weak manager] in
                manager?.setWindowFloating(!floating, forID: id)
            }
        } else {
            selectedMenuRule = nil
            configureWindowTilingMenuItem()
        }
        windowTilingMenuItem?.isHidden = selectedMenuRule.map {
            UserConfiguration.shared.excludesWindow(in: $0.bundleIdentifier, title: $0.title)
        } ?? false
        if showingExcludedWindows, let item = excludedWindowsMenu?.items.first {
            configureSaveExclusionItem(item, selected: selectedMenuRule, rules: UserConfiguration.shared.savedWindowExclusions, setExcluded: changeSavedExclusion)
        }
    }

    private func changeSavedExclusion(_ rule: WindowExclusion, enabled: Bool) {
        if let manager = windowManager {
            manager.setWindowExclusion(rule, enabled: enabled)
        } else {
            UserConfiguration.shared.setWindowExclusion(rule, enabled: enabled)
        }
    }

    func configureWindowTilingMenuItem(windowName: String? = nil, floating: Bool = false, perform: (() -> Void)? = nil) {
        guard let item = windowTilingMenuItem else { return }
        item.representedObject = perform
        item.target = self
        item.action = perform == nil ? nil : #selector(applyWindowTilingChoice(_:))
        item.isEnabled = perform != nil
        guard let windowName else {
            item.title = "Temporarily Exclude Selected Window"
            return
        }
        let name = Self.menuWindowName(windowName)
        item.title = floating ? "Return “\(name)” to Tiling" : "Temporarily Exclude “\(name)”"
    }

    private static func menuWindowName(_ title: String) -> String {
        let line = title.components(separatedBy: .newlines).joined(separator: " ")
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    private func configureSaveExclusionItem(_ item: NSMenuItem, selected: WindowExclusion?, rules: [WindowExclusion],
                                            setExcluded: @escaping (WindowExclusion, Bool) -> Void) {
        if let selected, !rules.contains(selected) {
            item.title = "Always Exclude “\(Self.menuWindowName(selected.title))”"
            item.target = self
            item.action = #selector(applyWindowTilingChoice(_:))
            item.toolTip = "\(selected.bundleIdentifier)\n\(selected.title)"
            item.representedObject = { setExcluded(selected, true) } as () -> Void
            item.isEnabled = true
        } else {
            item.title = selected == nil ? "Select a Window with a Title to Exclude" : "Selected Window Is Already Excluded"
            item.representedObject = nil
            item.action = nil
            item.toolTip = nil
            item.isEnabled = false
        }
    }

    func updateExcludedWindowsMenu(_ menu: NSMenu, selected: WindowExclusion?, rules: [WindowExclusion],
                                   setExcluded: @escaping (WindowExclusion, Bool) -> Void) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let saveItem = NSMenuItem()
        configureSaveExclusionItem(saveItem, selected: selected, rules: rules, setExcluded: setExcluded)
        menu.addItem(saveItem)
        menu.addItem(.separator())
        if rules.isEmpty {
            menu.addItem(withTitle: "No Saved Exclusions", action: nil, keyEquivalent: "").isEnabled = false
        }
        let runningApps = NSWorkspace.shared.runningApplications
        for rule in rules {
            let appName = runningApps.first { $0.bundleIdentifier == rule.bundleIdentifier }?.localizedName ?? rule.bundleIdentifier
            let title = "Remove “\(Self.menuWindowName(rule.title))” (\(appName))"
            let item = menu.addItem(withTitle: title, action: #selector(applyWindowTilingChoice(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = "\(rule.bundleIdentifier)\n\(rule.title)"
            item.representedObject = { setExcluded(rule, false) } as () -> Void
        }
    }

    @objc private func applyWindowTilingChoice(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    @IBAction func resetLayouts(_ sender: AnyObject) {
        UserDefaults.standard.removeObject(forKey: AppDelegate.windowManagerEncodingKey)
        windowManager?.reset()
    }

    @IBAction func relaunch(_ sender: AnyObject) {
        AppManager.relaunch()
    }

    @IBAction func showPreferencesWindow(_ sender: AnyObject) {
        guard let isVisible = preferencesWindowController?.window?.isVisible, !isVisible else {
            return
        }

        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        presentDotfileWarningIfNecessary()
    }

    @IBAction func checkForUpdates(_ sender: AnyObject) {
        #if RELEASE
            SUUpdater.shared().checkForUpdates(sender)
        #endif
    }

    private func presentDotfileWarningIfNecessary() {
        let shouldWarn = !UserDefaults.standard.bool(forKey: "disable-dotfile-conflict-warning")
        if shouldWarn && UserConfiguration.shared.hasCustomConfiguration() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Warning"
            alert.informativeText = "You have a .amethyst file, which can override in-app preferences. You may encounter unexpected behavior."
            alert.showsSuppressionButton = true
            alert.runModal()

            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "disable-dotfile-conflict-warning")
            }
        }
    }

    private func populateLayoutsMenu() {
        guard let layoutsMenuItem = layoutsMenuItem,
              let submenu = layoutsMenuItem.submenu else {
            return
        }

        let screen = layoutMenuScreen ?? statusItem?.button?.window?.screen ?? NSScreen.main
        let manager = screen.flatMap { windowManager?.screenManagerForLayoutMenu(on: AMScreen(screen: $0)) }
        updateLayoutsMenu(submenu, for: manager)
    }

    func updateLayoutsMenu(_ submenu: NSMenu, for manager: ScreenManager<WindowManager<SIApplication>>?) {
        submenu.removeAllItems()
        let config = UserConfiguration.shared
        let ready = manager?.space != nil
        let layouts: [LayoutMenuItemInfo]
        if ready, let manager {
            layouts = manager.layoutsInfo
        } else {
            layouts = config.layoutKeys().compactMap { key in
                guard let name = LayoutType<AXWindow>.layoutNameForKey(key) else { return nil }
                return LayoutMenuItemInfo(key: key, name: name, isSelected: false)
            }
        }

        if layouts.isEmpty {
            let noLayoutsItem = NSMenuItem(title: "No layouts enabled", action: nil, keyEquivalent: "")
            noLayoutsItem.isEnabled = false
            submenu.addItem(noLayoutsItem)
            return
        }

        for (index, layoutInfo) in layouts.enumerated() {
            let menuItem = NSMenuItem(title: layoutInfo.name, action: ready ? #selector(selectLayout(_:)) : nil, keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.identifier = NSUserInterfaceItemIdentifier(layoutInfo.key)
            menuItem.representedObject = manager
            menuItem.isEnabled = ready
            menuItem.state = layoutInfo.isSelected ? .on : .off

            submenu.addItem(menuItem)
        }

        submenu.addItem(.separator())
        guard ready else {
            submenu.addItem(withTitle: "Waiting for the current display and Space", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let defaultItem = NSMenuItem(
            title: "Use Current Layout as Default for This Display",
            action: #selector(useCurrentLayoutAsDisplayDefault(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.representedObject = manager
        submenu.addItem(defaultItem)
    }

    @objc private func useCurrentLayoutAsDisplayDefault(_ sender: NSMenuItem) {
        let manager = sender.representedObject as? ScreenManager<WindowManager<SIApplication>>
        manager?.useCurrentLayoutAsDisplayDefault()
    }

    @IBAction func selectLayout(_ sender: NSMenuItem) {
        guard let layoutKey = sender.identifier?.rawValue,
              let screenManager = sender.representedObject as? ScreenManager<WindowManager<SIApplication>> else {
            return
        }

        screenManager.selectLayout(at: sender.tag, matching: layoutKey)
    }

    @objc private func checkWindowAccess(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Window Access"
        if let app = sender.representedObject as? NSRunningApplication, !app.isTerminated {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1)
            var count = 0
            let result = AXUIElementGetAttributeValueCount(element, kAXWindowsAttribute as CFString, &count)
            let name = app.localizedName ?? "Selected app"
            let access: String
            switch result {
            case .success: access = "macOS reported \(count) windows for \(name)."
            case .apiDisabled: access = "macOS denied window access to \(name) (AX \(result.rawValue))."
            default: access = "The window list for \(name) could not be read (AX \(result.rawValue))."
            }
            let tracked = windowManager?.trackedWindowCount(for: app.processIdentifier) ?? 0
            let trust = AXIsProcessTrusted() ? "granted" : "not granted"
            alert.informativeText = "\(access)\nAmethyst is tracking \(tracked) windows for this app.\nProcess-wide access is \(trust)."
        } else {
            alert.informativeText = "Click a window in the app you want to check, then open this menu again."
        }
        alert.runModal()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        windowManager?.preferencesDidClose()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === excludedWindowsMenu {
            showingExcludedWindows = true
            return
        }
        guard menu === statusItemMenu, let app = NSWorkspace.shared.frontmostApplication,
              app.isManageable == .manageable else { return }
        let pid = app.processIdentifier
        menuWindowLookup.start(read: { AXWindow.menuSelection(forPID: pid) }) { [weak self] selection in
            guard let self, !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.menuSelectionResolved = true
            self.updateWindowTilingMenu(selection: selection, for: app)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === excludedWindowsMenu { showingExcludedWindows = false }
        guard menu === statusItemMenu else { return }
        menuWindowLookup.cancel()
        menuSelectionResolved = false
        selectedMenuRule = nil
        showingExcludedWindows = false
        // A new grant can trigger a full window scan. Do it after the tracking session.
        DispatchQueue.main.async { UserConfiguration.shared.refreshAccessibilityPermissions() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == statusItemMenu {
            let frontApp = NSWorkspace.shared.frontmostApplication
            let target = frontApp?.isManageable == .manageable ? frontApp : nil
            if !menuSelectionResolved {
                windowTilingMenuItem?.isHidden = false
                configureWindowTilingMenuItem()
            }
            permissionMenuItem.representedObject = target
            if let name = target?.localizedName {
                permissionMenuItem.title = "Check Window Access for \(name)…"
            } else {
                permissionMenuItem.title = "Check Window Access…"
            }
            let mouse = NSEvent.mouseLocation
            layoutMenuScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? statusItem?.button?.window?.screen
        } else if menu == layoutsMenuItem?.submenu {
            populateLayoutsMenu()
        } else if menu === excludedWindowsMenu {
            updateExcludedWindowsMenu(menu, selected: selectedMenuRule, rules: UserConfiguration.shared.savedWindowExclusions, setExcluded: changeSavedExclusion)
        }
    }
}

extension AppDelegate: UserConfigurationDelegate {
    func configurationLayoutsDidChange(_ userConfiguration: UserConfiguration) {
        windowManager?.reloadLayouts()
    }

    func configurationGlobalTilingDidChange(_ userConfiguration: UserConfiguration) {
        var statusItemImage: NSImage?
        if UserConfiguration.shared.tilingEnabled == true {
            statusItemImage = NSImage(named: "icon-statusitem")
            toggleGlobalTilingMenuItem?.title = "Disable Tiling"
        } else {
            statusItemImage = NSImage(named: "icon-statusitem-disabled")
            toggleGlobalTilingMenuItem?.title = "Enable Tiling"
        }
        statusItemImage?.isTemplate = true
        statusItem?.image = statusItemImage
    }

    func configurationAccessibilityPermissionsDidChange(_ userConfiguration: UserConfiguration) {
        // macOS can grant access to individual applications. Let AX decide for each target.
        if windowManager == nil {
            startWindowManagement()
        } else if userConfiguration.hasAccessibilityPermissions {
            windowManager?.reevaluateWindows()
        }
        guard userConfiguration.hasAccessibilityPermissions else {
            if permissionTimer == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                    guard self != nil else {
                        timer.invalidate()
                        return
                    }
                    userConfiguration.refreshAccessibilityPermissions()
                }
                RunLoop.main.add(timer, forMode: .common)
                permissionTimer = timer
            }
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}
