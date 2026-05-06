import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

final class Miri: NSObject, NSMenuDelegate, @unchecked Sendable {
    private enum LayoutSnapshotTiming {
        case immediate
        case deferred
    }

    private struct TrackpadNavigationSettings: Equatable {
        var enabled: Bool
        var fingers: Int
        var invertX: Bool
        var invertY: Bool
    }

    private struct TransientSystemWindow {
        var element: AXUIElement
    }

    private var loadedConfig = MiriConfig.loadWithMetadata()
    private var config: MiriConfig {
        loadedConfig.config
    }
    private var workspaces: [Workspace] = [Workspace()]
    private var floatingWindows: [ManagedWindow] = []
    private var activeWorkspace: Int = 0
    private weak var previousWorkspace: Workspace?
    private var observers: [pid_t: AXObserver] = [:]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var commandByKeybinding: [String: Command] = [:]
    private var excludedKeybindingSet = Set<String>()
    private var scheduledRescanTimer: DispatchSourceTimer?
    private var scheduledRescanAdoptFocused = false
    private var scheduledRescanProjectLayout = false
    private var pendingColumnNavigationDelta = 0
    private var pendingColumnNavigationTimer: DispatchSourceTimer?
    private var pendingColumnNavigationStartedAt: CFAbsoluteTime = 0
    private var pendingColumnNavigationProjectionState: LayoutState?
    private var columnNavigationFocusTimer: DispatchSourceTimer?
    private var columnNavigationFocusGeneration: UInt64 = 0
    private var lastColumnNavigationAt: CFAbsoluteTime = 0
    private var lastColumnNavigationDirection = 0
    private var rescanTimer: Timer?
    private var isApplyingLayout = false
    private var layoutLockGeneration: UInt64 = 0
    private var animationTimer: DispatchSourceTimer?
    private var animationGeneration: UInt64 = 0
    private var focusedWindowAdoptionSuppressedUntil: CFAbsoluteTime = 0
    private var expectedFocusedWindow: ObjectIdentifier?
    private var expectedFocusedWindowUntil: CFAbsoluteTime = 0
    private var focusRequestGeneration: UInt64 = 0
    private var focusVerificationGeneration: UInt64 = 0
    private var layoutVerificationGeneration: UInt64 = 0
    private var hoverFocusTimer: DispatchSourceTimer?
    private var hoverFocusTarget: ObjectIdentifier?
    private var hoverFocusRequiresRearm = false
    private var hoverFocusSuppressedUntil: CFAbsoluteTime = 0
    private var transientWindowActive = false
    private var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    private var trackpadNavigation: ThreeFingerTrackpadNavigation?
    private var trackpadCameraY: CGFloat?
    private var trackpadCameraVelocity = CGPoint.zero
    private var trackpadPendingCameraDelta = CGSize.zero
    private var trackpadLatestCameraVelocity = CGPoint.zero
    private var trackpadRenderTimer: DispatchSourceTimer?
    private var trackpadMomentumTimer: DispatchSourceTimer?
    private var trackpadMomentumLastFrameAt: CFAbsoluteTime = 0
    private var manualResizeEndTimer: DispatchSourceTimer?
    private var manualResizeElement: AXUIElement?
    private var manualResizeSuppressedUntil: CFAbsoluteTime = 0
    private var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    private var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    private var appliedAlphas: [UInt32: Float] = [:]
    private var appliedWindowLevels: [UInt32: Int32] = [:]
    private var snapshotWriteTimer: DispatchSourceTimer?
    private var pendingSnapshotViewport: CGRect?
    private var lastPersistentLayoutSnapshotData: Data?
    private var lastRestoreSnapshotData: Data?
    private var floatingRaiseGeneration: UInt64 = 0
    private lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    private var needsPersistentLayoutRestore = true
    private var signalSources: [DispatchSourceSignal] = []
    private let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miri-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    private var cleanupWatcher: Process?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let normalWindowLevel = Int32(CGWindowLevelForKey(.normalWindow))
    private let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    private let frameTimerInterval: DispatchTimeInterval = .milliseconds(16)
    private let frameTimerLeeway: DispatchTimeInterval = .milliseconds(1)

    func start() {
        guard requestAccessibilityPermission() else {
            fputs("miri: Accessibility permission is required. Enable it for this binary or Terminal, then run again.\n", stderr)
            exit(1)
        }

        observeWorkspace()
        installTerminationHandlers()
        if restoreOnExit {
            startCleanupWatcher()
        }
        configureInput()
        installEventTap()
        installTrackpadNavigation()
        installStatusItem()
        rescanWindows(adoptFocused: true)
        scheduleRescanTimer()

        print("miri: running")
        print("miri: loaded \(commandByKeybinding.count) keybindings")
        if trackpadNavigationEnabled {
            if trackpadNavigation != nil {
                print("miri: three-finger trackpad swipe navigates columns/workspaces")
            } else {
                print("miri: three-finger trackpad navigation unavailable; private MultitouchSupport backend did not start")
            }
        }
        print("miri: Cmd-Tab is passed through and adopted after macOS focuses a window")
        if hideMethod == .skyLightAlpha && !SkyLight.shared.canSetAlpha {
            print("miri: SkyLight alpha support unavailable; parked windows will remain as edge slivers")
        }
        runMainLoop()
    }

    private func installStatusItem() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.installStatusItem()
            }
            return
        }

        MainActor.assumeIsolated {
            installStatusItemOnMainActor()
        }
    }

    @MainActor
    private func installStatusItemOnMainActor() {
        _ = NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = statusBarIcon() {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.toolTip = "Miri"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItemOnMainActor()
    }

    private func updateStatusItem() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItem()
            }
            return
        }

        MainActor.assumeIsolated {
            updateStatusItemOnMainActor()
        }
    }

    @MainActor
    private func updateStatusItemOnMainActor() {
        guard let button = statusItem?.button else {
            return
        }

        button.title = button.image == nil ? "Miri" : ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            rebuildStatusMenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            MiriMenuItemFactory.refreshViewHeights(in: menu)
        }
    }

    @MainActor
    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.appearance = NSApp.effectiveAppearance

        let snapshot = statusMenuSnapshot
        menu.addItem(MiriMenuItemFactory.makeItem(for: MiriMenuHeaderView(snapshot: snapshot)))
        if snapshot.transientSystemDialogActive {
            menu.addItem(MiriMenuItemFactory.makeItem(for: MiriMenuBannerView(
                message: "System dialog is active. Miri is temporarily staying out of the way.",
                systemImage: "pause.circle"
            )))
        }
        menu.addItem(MiriMenuItemFactory.makeItem(for: MiriMenuDividerView()))

        addMenuItem(
            "Settings...",
            systemImage: "gearshape",
            action: #selector(presentSettingsFromStatusItem),
            to: menu
        )
        addMenuItem(
            "Reveal Settings in Finder",
            systemImage: "folder",
            action: #selector(revealConfigFromStatusItem),
            to: menu
        )
        addMenuItem(
            "Reveal Layout State",
            systemImage: "internaldrive",
            action: #selector(revealStateFromStatusItem),
            to: menu,
            enabled: FileManager.default.fileExists(atPath: persistentLayoutStateURL.path)
        )
        addMenuItem(
            "Donate to the Project",
            systemImage: "heart",
            action: #selector(openDonationFromStatusItem),
            to: menu
        )

        menu.addItem(MiriMenuItemFactory.makeItem(for: MiriMenuDividerView()))

        addMenuItem(
            "Reload Settings",
            systemImage: "arrow.clockwise",
            action: #selector(reloadConfigFromStatusItem),
            to: menu,
            enabled: FileManager.default.fileExists(atPath: settingsURL.path)
        )
        addMenuItem(
            "Reapply Layout",
            systemImage: "rectangle.3.group",
            action: #selector(reapplyLayoutFromStatusItem),
            to: menu
        )

        menu.addItem(MiriMenuItemFactory.makeItem(for: MiriMenuDividerView()))
        addMenuItem("Quit Miri", systemImage: "power", action: #selector(quitFromStatusItem), to: menu)
        MiriMenuItemFactory.refreshViewHeights(in: menu)
    }

    private var statusMenuSnapshot: MiriMenuSnapshot {
        let workspace = activeWorkspaceObject()
        let activeWindow: ManagedWindow?
        if let workspace, !workspace.columns.isEmpty {
            workspace.clampFocus()
            activeWindow = workspace.columns[workspace.activeColumn]
        } else {
            activeWindow = nil
        }

        return MiriMenuSnapshot(
            workspaceIndex: activeWorkspace + 1,
            columnIndex: activeWindow == nil ? nil : (workspace?.activeColumn ?? 0) + 1,
            columnCount: workspace?.columns.count ?? 0,
            activeAppName: activeWindow?.appName ?? "No tiled window",
            settingsPath: abbreviatedPath(settingsURL),
            layoutStatePath: persistLayoutEnabled ? abbreviatedPath(persistentLayoutStateURL) : nil,
            layoutStateExists: FileManager.default.fileExists(atPath: persistentLayoutStateURL.path),
            transientSystemDialogActive: transientWindowActive
        )
    }

    private var settingsURL: URL {
        if let sourceURL = loadedConfig.sourceURL {
            return sourceURL
        }

        if let path = ProcessInfo.processInfo.environment["MIRI_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }

        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return xdgConfig.appendingPathComponent("miri/config.json")
    }

    private func abbreviatedPath(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }

    private func addMenuItem(
        _ title: String,
        systemImage: String,
        action: Selector,
        to menu: NSMenu,
        enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = menuImage(systemImage, description: title)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func statusBarIcon() -> NSImage? {
        for name in ["rectangle.3.group", "square.grid.2x2", "rectangle.grid.1x2"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Miri") {
                return image
            }
        }
        return nil
    }

    private func menuImage(_ systemName: String, description: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    @MainActor
    @objc private func presentSettingsFromStatusItem() {
        presentSettingsView()
    }

    @MainActor
    private func presentSettingsView() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Settings"
        settingsWindow.titleVisibility = .visible
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.titlebarSeparatorStyle = .none
        settingsWindow.toolbarStyle = .unified
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = NSHostingView(rootView: MiriSettingsView(
            config: config,
            settingsURL: settingsURL,
            stateURL: persistentLayoutStateURL,
            onSave: { [weak self] config in
                self?.saveConfigFromSettingsWindow(config) ?? false
            },
            onRevealSettings: { [weak self] in
                self?.revealConfigFromStatusItem()
            },
            onRevealState: { [weak self] in
                self?.revealStateFromStatusItem()
            }
        ))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = settingsWindow
    }

    @objc private func revealConfigFromStatusItem() {
        guard let url = ensureSettingsFileExists() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func revealStateFromStatusItem() {
        let url = persistentLayoutStateURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openDonationFromStatusItem() {
        guard let url = URL(string: "https://ko-fi.com/maria_rcks") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func reloadConfigFromStatusItem() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            NSSound.beep()
            return
        }

        loadedConfig.sourceModificationDate = nil
        guard reloadConfigIfNeeded() else {
            NSSound.beep()
            return
        }
        updateStatusItem()
    }

    private func ensureSettingsFileExists() -> URL? {
        let url = settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(config)
            try data.write(to: url, options: [.atomic])
            loadedConfig.sourceURL = url
            loadedConfig.sourceModificationDate = MiriConfig.modificationDate(for: url)
            print("miri: created settings \(url.path)")
            return url
        } catch {
            fputs("miri: failed to create settings \(url.path): \(error)\n", stderr)
            return nil
        }
    }

    @objc private func reapplyLayoutFromStatusItem() {
        cancelHoverFocus()
        clearTrackpadCamera()
        clearAppliedLayoutCache()
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
        updateStatusItem()
    }

    @objc private func quitFromStatusItem() {
        restoreManagedWindowsForExit()
        exit(0)
    }

    private func runMainLoop() {
        guard statusItem != nil, Thread.isMainThread else {
            RunLoop.main.run()
            return
        }

        MainActor.assumeIsolated {
            NSApplication.shared.run()
        }
    }

    private func makeMainTimer(
        deadline: DispatchTime,
        repeating interval: DispatchTimeInterval? = nil,
        leeway: DispatchTimeInterval = .milliseconds(2),
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        if let interval {
            timer.schedule(deadline: deadline, repeating: interval, leeway: leeway)
        } else {
            timer.schedule(deadline: deadline, leeway: leeway)
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func cancelTimer(_ timer: inout DispatchSourceTimer?) {
        timer?.cancel()
        timer = nil
    }

    private func scheduleRescanTimer() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanInterval, repeats: true) { [weak self] _ in
            self?.handlePeriodicTick()
        }
    }

    private func handlePeriodicTick() {
        guard !reloadConfigIfNeeded() else {
            return
        }
        let wasTransient = transientWindowActive
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        rescanWindows(adoptFocused: wasTransient)
    }

    @discardableResult
    private func reloadConfigIfNeeded() -> Bool {
        let previousSourceURL = loadedConfig.sourceURL
        let previousModificationDate = loadedConfig.sourceModificationDate

        if let previousSourceURL {
            let currentModificationDate = MiriConfig.modificationDate(for: previousSourceURL)
            guard currentModificationDate != previousModificationDate else {
                return false
            }

            loadedConfig.sourceModificationDate = currentModificationDate
        }

        return reloadConfigFromDisk(previousSourceURL: previousSourceURL)
    }

    @discardableResult
    private func reloadConfigFromDisk(previousSourceURL: URL?) -> Bool {
        let reloaded = MiriConfig.loadWithMetadata(logLoaded: false)

        guard reloaded.sourceURL != nil else {
            if previousSourceURL != nil {
                fputs("miri: config reload skipped; keeping previous config\n", stderr)
            }
            return false
        }

        applyLoadedConfig(reloaded)
        let sourcePath = loadedConfig.sourceURL?.path ?? "fallback"
        print("miri: reloaded config \(sourcePath), \(commandByKeybinding.count) keybindings")
        return true
    }

    @discardableResult
    private func saveConfigFromSettingsWindow(_ newConfig: MiriConfig) -> Bool {
        let url = settingsURL

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(newConfig)
            try data.write(to: url, options: [.atomic])

            applyLoadedConfig(LoadedMiriConfig(
                config: MiriConfig.normalize(newConfig),
                sourceURL: url,
                sourceModificationDate: MiriConfig.modificationDate(for: url)
            ))
            updateStatusItem()

            print("miri: saved settings \(url.path)")
            return true
        } catch {
            fputs("miri: failed to save settings \(url.path): \(error)\n", stderr)
            return false
        }
    }

    private func applyLoadedConfig(_ newLoadedConfig: LoadedMiriConfig) {
        let previousRescanInterval = rescanInterval
        let previousRestoreOnExit = restoreOnExit
        let previousTrackpadSettings = trackpadNavigationSettings

        loadedConfig = newLoadedConfig
        configureInput()

        if trackpadNavigationSettings != previousTrackpadSettings {
            restartTrackpadNavigation()
        }
        if rescanInterval != previousRescanInterval {
            scheduleRescanTimer()
        }
        updateCleanupWatcher(previousRestoreOnExit: previousRestoreOnExit)
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
    }

    private func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.restoreOnExit == true {
                    self?.restoreManagedWindowsForExit()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startCleanupWatcher() {
        guard let executableURL = currentExecutableURL() else {
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cleanup-watch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            restoreStateURL.path,
        ]

        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }

        do {
            try process.run()
            cleanupWatcher = process
        } catch {
            fputs("miri: failed to start cleanup watcher: \(error)\n", stderr)
        }
    }

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            fputs("miri: unable to create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
            exit(1)
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("miri: unable to create event tap run loop source.\n", stderr)
            exit(1)
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private func installTrackpadNavigation() {
        guard trackpadNavigationEnabled else {
            return
        }

        let navigation = ThreeFingerTrackpadNavigation(
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleTrackpadNavigationEvent(event)
            }
        }

        guard navigation.start() else { return }

        trackpadNavigation = navigation
    }

    private func restartTrackpadNavigation() {
        trackpadNavigation?.stop()
        trackpadNavigation = nil
        clearTrackpadCamera()
        installTrackpadNavigation()
    }

    private func updateCleanupWatcher(previousRestoreOnExit: Bool) {
        guard restoreOnExit != previousRestoreOnExit else {
            return
        }

        if restoreOnExit {
            startCleanupWatcher()
        } else {
            cleanupWatcher?.terminate()
            cleanupWatcher = nil
            try? FileManager.default.removeItem(at: restoreStateURL)
        }
    }

    private func configureInput() {
        commandByKeybinding = makeCommandByKeybinding()
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(normalizedKeybinding(_:)))
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> Bool {
        guard !transientSystemWindowIsActive() else {
            return false
        }

        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyText = keyboardText(from: event)
        guard !isExcludedKeybinding(modifiers: modifiers, keyCode: keyCode, keyText: keyText) else {
            return false
        }

        guard let command = commandForKeyEvent(modifiers: modifiers, keyCode: keyCode, keyText: keyText) else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.handle(command)
        }
        return true
    }

    private func handle(_ command: Command) {
        switch command {
        case .columnLeft:
            enqueueColumnNavigation(delta: -1)
        case .columnRight:
            enqueueColumnNavigation(delta: 1)
        default:
            flushPendingColumnNavigation()
            flushColumnNavigationProjection(animated: false)
            cancelColumnNavigationFocus()
            perform(command)
        }
    }

    private func enqueueColumnNavigation(delta: Int) {
        guard delta != 0 else {
            return
        }

        pendingColumnNavigationDelta += delta
        let now = CFAbsoluteTimeGetCurrent()
        if pendingColumnNavigationStartedAt == 0 {
            pendingColumnNavigationStartedAt = now
        }
        let burstActive = columnNavigationInputBurstIsActive()
        let delay: DispatchTimeInterval = burstActive
            ? (now - pendingColumnNavigationStartedAt >= 0.11 ? .milliseconds(1) : .milliseconds(55))
            : .milliseconds(6)
        if let pendingColumnNavigationTimer {
            if burstActive {
                pendingColumnNavigationTimer.schedule(
                    deadline: .now() + delay,
                    leeway: .milliseconds(4)
                )
            }
            return
        }

        pendingColumnNavigationTimer = makeMainTimer(deadline: .now() + delay) { [weak self] in
            self?.flushPendingColumnNavigation()
        }
    }

    private func flushPendingColumnNavigation() {
        cancelTimer(&pendingColumnNavigationTimer)
        pendingColumnNavigationStartedAt = 0

        let delta = pendingColumnNavigationDelta
        pendingColumnNavigationDelta = 0
        guard delta != 0 else {
            return
        }

        performColumnNavigation(by: delta)
    }

    private func columnNavigationInputBurstIsActive() -> Bool {
        animationTimer != nil
            || pendingColumnNavigationProjectionState != nil
            || columnNavigationFocusTimer != nil
            || CFAbsoluteTimeGetCurrent() - lastColumnNavigationAt < 0.18
    }

    private func scheduleColumnNavigationFocus(after delay: TimeInterval) {
        guard let window = activeWindow() else {
            cancelColumnNavigationFocus()
            return
        }

        cancelTimer(&columnNavigationFocusTimer)
        columnNavigationFocusGeneration &+= 1
        let generation = columnNavigationFocusGeneration
        let windowID = ObjectIdentifier(window)
        let focusDelay = max(delay, 0.02)
        markExpectedFocusedWindow(for: window, duration: focusDelay + 1.0)
        suppressFocusedWindowAdoption(for: focusDelay + 0.5)

        columnNavigationFocusTimer = makeMainTimer(
            deadline: .now() + focusDelay,
            leeway: .milliseconds(4)
        ) { [weak self] in
            self?.settleColumnNavigationFocus(windowID: windowID, generation: generation)
        }
    }

    private func settleColumnNavigationFocus(windowID: ObjectIdentifier, generation: UInt64) {
        guard generation == columnNavigationFocusGeneration else {
            return
        }

        cancelTimer(&columnNavigationFocusTimer)
        guard pendingColumnNavigationProjectionState == nil
        else {
            scheduleColumnNavigationFocus(after: 0.025)
            return
        }

        guard let window = activeWindow(),
              ObjectIdentifier(window) == windowID
        else {
            return
        }

        guard animationTimer == nil else {
            scheduleColumnNavigationFocus(after: 0.025)
            return
        }

        focus(window, verify: true)
    }

    private func cancelColumnNavigationFocus() {
        columnNavigationFocusGeneration &+= 1
        cancelTimer(&columnNavigationFocusTimer)
    }

    private func flushColumnNavigationProjection(animated: Bool) {
        guard let previousState = pendingColumnNavigationProjectionState else {
            return
        }
        pendingColumnNavigationProjectionState = nil

        let targetState = captureLayoutState()
        let shouldAnimate = animated && (previousState != targetState || !presentationFrames.isEmpty)
        let duration = shouldAnimate ? columnNavigationRetargetAnimationDuration : 0
        projectLayout(
            focusActiveWindow: false,
            animated: shouldAnimate,
            from: previousState,
            animationDuration: duration,
            layoutLockDelay: 0.04,
            prefocusActiveWindow: false,
            snapshotTiming: .deferred,
            verifyActiveLayout: false
        )
        scheduleColumnNavigationFocus(after: duration + 0.025)
    }

    private func makeCommandByKeybinding() -> [String: Command] {
        var configured = MiriConfig.defaultKeybindings
        for (name, bindings) in config.keybindings ?? [:] {
            configured[name] = bindings
        }

        var commands: [String: Command] = [:]
        for name in configured.keys.sorted() {
            let bindings = configured[name] ?? []
            guard let command = command(named: name) else {
                fputs("miri: ignoring unknown keybinding command '\(name)'\n", stderr)
                continue
            }

            for binding in bindings {
                guard let normalized = normalizedKeybinding(binding) else {
                    fputs("miri: ignoring invalid keybinding '\(binding)' for '\(name)'\n", stderr)
                    continue
                }
                if commands[normalized] != nil {
                    fputs("miri: keybinding '\(binding)' is assigned more than once; using '\(name)'\n", stderr)
                }
                commands[normalized] = command
            }
        }

        return commands
    }

    private func commandForKeyEvent(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> Command? {
        for candidate in normalizedKeybindingCandidates(modifiers: modifiers, keyCode: keyCode, keyText: keyText) {
            if let command = commandByKeybinding[candidate] {
                return command
            }
        }
        return nil
    }

    private func command(named name: String) -> Command? {
        if let index = commandIndex(name, prefix: "focus_workspace_") {
            return .focusWorkspace(index)
        }
        if let index = commandIndex(name, prefix: "move_column_to_workspace_") {
            return .moveColumnToWorkspace(index)
        }

        switch name {
        case "focus_previous_workspace":
            return .focusPreviousWorkspace
        case "workspace_down":
            return .workspaceDown
        case "workspace_up":
            return .workspaceUp
        case "column_left":
            return .columnLeft
        case "column_right":
            return .columnRight
        case "column_first":
            return .columnFirst
        case "column_last":
            return .columnLast
        case "move_column_left":
            return .moveColumnLeft
        case "move_column_right":
            return .moveColumnRight
        case "move_column_to_first":
            return .moveColumnToFirst
        case "move_column_to_last":
            return .moveColumnToLast
        case "move_column_down":
            return .moveColumnToWorkspaceDown
        case "move_column_up":
            return .moveColumnToWorkspaceUp
        case "cycle_width_preset_backward":
            return .cycleWidthPresetBackward
        case "cycle_width_preset_forward":
            return .cycleWidthPresetForward
        case "nudge_width_narrower":
            return .nudgeWidthNarrower
        case "nudge_width_wider":
            return .nudgeWidthWider
        case "cycle_all_width_presets_backward":
            return .cycleAllWidthPresetsBackward
        case "cycle_all_width_presets_forward":
            return .cycleAllWidthPresetsForward
        case "nudge_all_widths_narrower":
            return .nudgeAllWidthsNarrower
        case "nudge_all_widths_wider":
            return .nudgeAllWidthsWider
        default:
            return nil
        }
    }

    private func commandIndex(_ name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix),
              let index = Int(name.dropFirst(prefix.count)),
              (1...9).contains(index)
        else {
            return nil
        }
        return index
    }

    private func keyboardText(from event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    private func isExcludedKeybinding(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> Bool {
        guard !excludedKeybindingSet.isEmpty else {
            return false
        }

        for candidate in normalizedKeybindingCandidates(modifiers: modifiers, keyCode: keyCode, keyText: keyText) {
            if excludedKeybindingSet.contains(candidate) {
                return true
            }
        }

        return false
    }

    private func normalizedKeybindingCandidates(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> [String] {
        var candidates: [String] = []
        let appendCandidates: ([String], [String]) -> Void = { modifierParts, keyNames in
            for keyName in keyNames {
                let candidate = (modifierParts + [keyName]).joined(separator: "+")
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }

        appendCandidates(
            normalizedModifierParts(from: modifiers),
            normalizedKeyNames(
                keyCode: keyCode,
                keyText: keyText,
                includeFnNavigationAliases: modifiers.contains(.maskSecondaryFn)
            )
        )

        if modifiers.contains(.maskSecondaryFn) {
            var legacyModifiers = modifiers
            legacyModifiers.remove(.maskSecondaryFn)
            appendCandidates(
                normalizedModifierParts(from: legacyModifiers),
                normalizedKeyNames(keyCode: keyCode, keyText: keyText, includeFnNavigationAliases: false)
            )
        }

        return candidates
    }

    private func normalizedKeyNames(keyCode: Int64, keyText: String, includeFnNavigationAliases: Bool) -> [String] {
        var names: [String] = []
        let add: (String) -> Void = { name in
            let normalized = self.normalizedKeyName(name)
            if !names.contains(normalized) {
                names.append(normalized)
            }
        }

        if !keyText.isEmpty {
            add(keyText)
        }

        for name in Self.keyNamesByCode[keyCode] ?? [] {
            add(name)
        }

        if includeFnNavigationAliases {
            for name in Self.fnNavigationKeyAliasesByCode[keyCode] ?? [] {
                add(name)
            }
        }

        return names
    }

    private func normalizedKeybinding(_ binding: String) -> String? {
        let parts = binding
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers = Set<String>()
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert("cmd")
            case "ctrl", "control":
                modifiers.insert("ctrl")
            case "shift":
                modifiers.insert("shift")
            case "alt", "option", "alternate":
                modifiers.insert("alt")
            case "fn", "function", "globe":
                modifiers.insert("fn")
            default:
                key = normalizedKeyName(part)
            }
        }

        guard let key else {
            return nil
        }

        return (orderedModifierParts(from: modifiers) + [key]).joined(separator: "+")
    }

    private func normalizedModifierParts(from modifiers: CGEventFlags) -> [String] {
        var names = Set<String>()
        if modifiers.contains(.maskCommand) {
            names.insert("cmd")
        }
        if modifiers.contains(.maskControl) {
            names.insert("ctrl")
        }
        if modifiers.contains(.maskShift) {
            names.insert("shift")
        }
        if modifiers.contains(.maskAlternate) {
            names.insert("alt")
        }
        if modifiers.contains(.maskSecondaryFn) {
            names.insert("fn")
        }
        return orderedModifierParts(from: names)
    }

    private func orderedModifierParts(from modifiers: Set<String>) -> [String] {
        ["cmd", "ctrl", "shift", "alt", "fn"].filter { modifiers.contains($0) }
    }

    private func normalizedKeyName(_ key: String) -> String {
        Self.keyNameAliases[key.lowercased()] ?? key
    }

    private static let keyNamesByCode: [Int64: [String]] = [
        // ANSI letter keys.
        KeyCode.a: ["a"],
        KeyCode.b: ["b"],
        KeyCode.c: ["c"],
        KeyCode.d: ["d"],
        KeyCode.e: ["e"],
        KeyCode.f: ["f"],
        KeyCode.g: ["g"],
        KeyCode.h: ["h"],
        KeyCode.i: ["i"],
        KeyCode.j: ["j"],
        KeyCode.k: ["k"],
        KeyCode.l: ["l"],
        KeyCode.m: ["m"],
        KeyCode.n: ["n"],
        KeyCode.o: ["o"],
        KeyCode.p: ["p"],
        KeyCode.q: ["q"],
        KeyCode.r: ["r"],
        KeyCode.s: ["s"],
        KeyCode.t: ["t"],
        KeyCode.u: ["u"],
        KeyCode.v: ["v"],
        KeyCode.w: ["w"],
        KeyCode.x: ["x"],
        KeyCode.y: ["y"],
        KeyCode.z: ["z"],

        // ANSI number row.
        KeyCode.one: ["1"],
        KeyCode.two: ["2"],
        KeyCode.three: ["3"],
        KeyCode.four: ["4"],
        KeyCode.five: ["5"],
        KeyCode.six: ["6"],
        KeyCode.seven: ["7"],
        KeyCode.eight: ["8"],
        KeyCode.nine: ["9"],
        KeyCode.zero: ["0"],

        // ANSI punctuation and symbols.
        KeyCode.minus: ["-", "minus"],
        KeyCode.equal: ["=", "equal"],
        KeyCode.leftBracket: ["[", "{"],
        KeyCode.rightBracket: ["]", "}"],
        KeyCode.semicolon: [";"],
        KeyCode.quote: ["'"],
        KeyCode.comma: [","],
        KeyCode.period: ["."],
        KeyCode.slash: ["/"],
        KeyCode.backslash: ["\\"],
        KeyCode.grave: ["`"],

        // Editing and whitespace keys.
        KeyCode.tab: ["tab"],
        KeyCode.space: ["space"],
        KeyCode.returnKey: ["return", "enter"],
        KeyCode.escape: ["escape"],
        KeyCode.delete: ["delete", "backspace"],
        KeyCode.forwardDelete: ["forward-delete"],

        // Navigation keys.
        KeyCode.home: ["home"],
        KeyCode.end: ["end"],
        KeyCode.pageUp: ["pageup"],
        KeyCode.pageDown: ["pagedown"],
        KeyCode.leftArrow: ["left"],
        KeyCode.rightArrow: ["right"],
        KeyCode.upArrow: ["up"],
        KeyCode.downArrow: ["down"],

        // Function keys.
        KeyCode.f1: ["f1"],
        KeyCode.f2: ["f2"],
        KeyCode.f3: ["f3"],
        KeyCode.f4: ["f4"],
        KeyCode.f5: ["f5"],
        KeyCode.f6: ["f6"],
        KeyCode.f7: ["f7"],
        KeyCode.f8: ["f8"],
        KeyCode.f9: ["f9"],
        KeyCode.f10: ["f10"],
        KeyCode.f11: ["f11"],
        KeyCode.f12: ["f12"],
    ]

    private static let fnNavigationKeyAliasesByCode: [Int64: [String]] = [
        KeyCode.leftArrow: ["home"],
        KeyCode.rightArrow: ["end"],
        KeyCode.upArrow: ["pageup"],
        KeyCode.downArrow: ["pagedown"],
        KeyCode.home: ["left"],
        KeyCode.end: ["right"],
        KeyCode.pageUp: ["up"],
        KeyCode.pageDown: ["down"],
    ]

    private static let keyNameAliases: [String: String] = [
        // Brackets and braces.
        "leftbracket": "[",
        "left-bracket": "[",
        "openbracket": "[",
        "open-bracket": "[",
        "rightbracket": "]",
        "right-bracket": "]",
        "closebracket": "]",
        "close-bracket": "]",
        "leftbrace": "{",
        "left-brace": "{",
        "openbrace": "{",
        "open-brace": "{",
        "rightbrace": "}",
        "right-brace": "}",
        "closebrace": "}",
        "close-brace": "}",

        // Punctuation and symbols.
        "minus": "-",
        "hyphen": "-",
        "dash": "-",
        "equal": "=",
        "equals": "=",
        "semicolon": ";",
        "quote": "'",
        "apostrophe": "'",
        "singlequote": "'",
        "single-quote": "'",
        "comma": ",",
        "period": ".",
        "dot": ".",
        "fullstop": ".",
        "full-stop": ".",
        "slash": "/",
        "forwardslash": "/",
        "forward-slash": "/",
        "backslash": "\\",
        "back-slash": "\\",
        "grave": "`",
        "backtick": "`",
        "backquote": "`",

        // Editing and whitespace keys.
        "esc": "escape",
        "enter": "return",
        "backspace": "delete",
        "forwarddelete": "forward-delete",
        "fwddelete": "forward-delete",
        "del": "forward-delete",
        "spacebar": "space",

        // Navigation keys.
        "leftarrow": "left",
        "left-arrow": "left",
        "arrowleft": "left",
        "arrow-left": "left",
        "rightarrow": "right",
        "right-arrow": "right",
        "arrowright": "right",
        "arrow-right": "right",
        "uparrow": "up",
        "up-arrow": "up",
        "arrowup": "up",
        "arrow-up": "up",
        "downarrow": "down",
        "down-arrow": "down",
        "arrowdown": "down",
        "arrow-down": "down",
        "pgup": "pageup",
        "page-up": "pageup",
        "page_up": "pageup",
        "pgdn": "pagedown",
        "pgdown": "pagedown",
        "page-down": "pagedown",
        "page_down": "pagedown",
    ]

    fileprivate func handleMouseMoved(_ event: CGEvent) {
        guard hoverFocusEnabled,
              !transientSystemWindowIsActive(),
              manualResizeElement == nil,
              animationTimer == nil,
              !isApplyingLayout
        else {
            cancelHoverFocus()
            return
        }

        guard CFAbsoluteTimeGetCurrent() >= hoverFocusSuppressedUntil else {
            cancelHoverFocus()
            return
        }

        let point = event.location
        if shouldSuppressHoverFocusUntilRearmed(at: point) {
            cancelHoverFocus()
            return
        }

        guard let target = hoverFocusTarget(at: point) else {
            cancelHoverFocus()
            return
        }

        if target.immediate {
            performHoverFocus(window: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        } else {
            scheduleHoverFocus(for: target.window, workspaceIndex: target.workspaceIndex, columnIndex: target.columnIndex)
        }
    }

    private func handleTrackpadNavigationEvent(_ event: TrackpadNavigationEvent) {
        guard trackpadNavigationEnabled,
              !transientSystemWindowIsActive(),
              trackpadNavigationAllowedForActiveWindow
        else {
            return
        }

        switch event {
        case .began:
            beginTrackpadCamera()
        case .changed(let delta, let velocity):
            moveTrackpadCamera(delta: delta, velocity: velocity)
        case .ended(let velocity):
            endTrackpadCamera(velocity: velocity)
        }
    }

    private func beginTrackpadCamera() {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        cancelHoverFocus()
        flushPendingColumnNavigation()
        flushColumnNavigationProjection(animated: false)
        cancelColumnNavigationFocus()
        hoverFocusRequiresRearm = false
        stopTrackpadMomentum()
        stopAnimation(clearPresentation: false)
        rescanWindows(adoptFocused: false)
        resetTrackpadCameraMotion(clearCameraY: false)
        seedTrackpadCamera(viewport: currentViewport())
        startTrackpadRenderLoop()
    }

    private func moveTrackpadCamera(delta: CGPoint, velocity: CGPoint) {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let cameraDelta = trackpadCameraDelta(from: delta, velocity: velocity, viewport: viewport)
        trackpadPendingCameraDelta.width += cameraDelta.width
        trackpadPendingCameraDelta.height += cameraDelta.height
        trackpadLatestCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        trackpadCameraVelocity = trackpadLatestCameraVelocity
        startTrackpadRenderLoop()
    }

    private func endTrackpadCamera(velocity: CGPoint) {
        suppressHoverFocusAfterTrackpadMovement()
        flushTrackpadCameraFrame()
        stopTrackpadRenderLoop()
        let viewport = currentViewport()
        trackpadCameraVelocity = strongestTrackpadCameraVelocity(
            endingVelocity: trackpadCameraVelocity(from: velocity, viewport: viewport)
        )

        guard hasTrackpadMomentumVelocity else {
            settleTrackpadCamera(focusActiveWindow: true)
            return
        }

        startTrackpadMomentum()
    }

    private func trackpadCameraDelta(from delta: CGPoint, velocity: CGPoint, viewport: CGRect) -> CGSize {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGSize(
            width: -delta.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            height: delta.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    private func trackpadCameraVelocity(from velocity: CGPoint, viewport: CGRect) -> CGPoint {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGPoint(
            x: -velocity.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            y: velocity.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    private func trackpadCameraVelocityGain(for velocity: CGPoint) -> CGFloat {
        let speed = hypot(velocity.x, velocity.y)
        let extra = min(max((speed - 0.35) / 1.4, 0), trackpadNavigationVelocityGain)
        return 1 + extra
    }

    private var hasPendingTrackpadCameraDelta: Bool {
        abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5
    }

    private var hasTrackpadMomentumVelocity: Bool {
        abs(trackpadCameraVelocity.x) >= trackpadNavigationMomentumMinVelocity
            || abs(trackpadCameraVelocity.y) >= trackpadNavigationMomentumMinVelocity
    }

    private func strongestTrackpadCameraVelocity(endingVelocity: CGPoint) -> CGPoint {
        CGPoint(
            x: abs(endingVelocity.x) >= abs(trackpadLatestCameraVelocity.x)
                ? endingVelocity.x
                : trackpadLatestCameraVelocity.x,
            y: abs(endingVelocity.y) >= abs(trackpadLatestCameraVelocity.y)
                ? endingVelocity.y
                : trackpadLatestCameraVelocity.y
        )
    }

    private func resetTrackpadCameraMotion(clearCameraY: Bool) {
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadCameraVelocity = .zero
        if clearCameraY {
            trackpadCameraY = nil
        }
    }

    private func suppressHoverFocusAfterTrackpadMovement() {
        hoverFocusSuppressedUntil = CFAbsoluteTimeGetCurrent() + hoverFocusAfterTrackpad
        cancelHoverFocus()
    }

    private func seedTrackpadCamera(viewport: CGRect) {
        if trackpadCameraY == nil {
            trackpadCameraY = CGFloat(activeWorkspace) * viewport.height
        }

        if let workspace = activeWorkspaceObject(), workspace.scrollOffset == nil {
            workspace.scrollOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        }
    }

    private func startTrackpadMomentum() {
        stopTrackpadMomentum()
        trackpadMomentumLastFrameAt = CFAbsoluteTimeGetCurrent()

        trackpadMomentumTimer = makeMainTimer(
            deadline: .now(),
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            self?.stepTrackpadMomentum()
        }
    }

    private func startTrackpadRenderLoop() {
        guard trackpadRenderTimer == nil else {
            return
        }

        trackpadRenderTimer = makeMainTimer(
            deadline: .now(),
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            self?.flushTrackpadCameraFrame()
        }
    }

    private func stopTrackpadRenderLoop() {
        cancelTimer(&trackpadRenderTimer)
    }

    private func flushTrackpadCameraFrame() {
        guard hasPendingTrackpadCameraDelta else {
            return
        }

        guard manualResizeElement == nil else {
            trackpadPendingCameraDelta = .zero
            stopTrackpadRenderLoop()
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let delta = trackpadPendingCameraDelta
        trackpadPendingCameraDelta = .zero
        _ = applyTrackpadCameraDelta(delta, viewport: viewport)
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0, snapshotTiming: .deferred)
    }

    private func stepTrackpadMomentum() {
        suppressHoverFocusAfterTrackpadMovement()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(max(now - trackpadMomentumLastFrameAt, 1.0 / 120.0), 1.0 / 20.0)
        trackpadMomentumLastFrameAt = now

        let viewport = currentViewport()
        let decay = exp(-trackpadNavigationDeceleration * elapsed)
        trackpadCameraVelocity.x *= decay
        trackpadCameraVelocity.y *= decay

        let cameraDelta = CGSize(
            width: trackpadCameraVelocity.x * elapsed,
            height: trackpadCameraVelocity.y * elapsed
        )
        let clamped = applyTrackpadCameraDelta(cameraDelta, viewport: viewport)
        if clamped.x {
            trackpadCameraVelocity.x = 0
        }
        if clamped.y {
            trackpadCameraVelocity.y = 0
        }

        projectLayout(focusActiveWindow: false, layoutLockDelay: 0, snapshotTiming: .deferred)

        if !hasTrackpadMomentumVelocity {
            stopTrackpadMomentum()
            settleTrackpadCamera(focusActiveWindow: true)
        }
    }

    private func stopTrackpadMomentum() {
        cancelTimer(&trackpadMomentumTimer)
    }

    @discardableResult
    private func applyTrackpadCameraDelta(_ delta: CGSize, viewport: CGRect) -> (x: Bool, y: Bool) {
        let currentY = trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height
        let maxY = max(0, CGFloat(max(workspaces.count - 1, 0)) * viewport.height)
        let nextY = min(max(currentY + delta.height, 0), maxY)
        trackpadCameraY = nextY

        let workspaceIndex = trackpadCameraWorkspaceIndex(cameraY: nextY, viewport: viewport)
        var clampedX = false
        if workspaces.indices.contains(workspaceIndex) {
            let workspace = workspaces[workspaceIndex]
            if !workspace.columns.isEmpty {
                let currentX = horizontalCameraOffset(for: workspace, viewport: viewport)
                let maxX = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
                let nextX = min(max(currentX + delta.width, 0), maxX)
                workspace.scrollOffset = nextX
                clampedX = abs(nextX - (currentX + delta.width)) > 0.5
            } else {
                clampedX = abs(delta.width) > 0.5
            }
        } else {
            clampedX = abs(delta.width) > 0.5
        }

        let clampedY = abs(nextY - (currentY + delta.height)) > 0.5
        return (clampedX, clampedY)
    }

    private func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            resetTrackpadCameraMotion(clearCameraY: true)
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let previousState = captureLayoutState()
        let targetWorkspace = trackpadCameraWorkspaceIndex(
            cameraY: trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height,
            viewport: viewport
        )
        setActiveWorkspace(targetWorkspace)

        if let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty {
            let offset = horizontalCameraOffset(for: workspace, viewport: viewport)
            switch trackpadNavigationSnap {
            case .nearestColumn:
                workspace.activeColumn = closestColumn(to: offset, in: workspace, viewport: viewport)
                workspace.scrollOffset = nil
            case .nearestVisible:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            case .none:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            }
        }

        resetTrackpadCameraMotion(clearCameraY: trackpadNavigationSnap != .none)
        hoverFocusRequiresRearm = true
        suppressHoverFocusAfterTrackpadMovement()

        let targetState = captureLayoutState()
        projectLayout(
            focusActiveWindow: focusActiveWindow,
            animated: previousState != targetState,
            from: previousState,
            animationDuration: trackpadSettleAnimationDuration,
            layoutLockDelay: 0.04
        )
    }

    private func clearTrackpadCamera() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()
        resetTrackpadCameraMotion(clearCameraY: true)
    }

    private func freezeTrackpadCameraForTransition() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()

        if hasPendingTrackpadCameraDelta {
            let viewport = currentViewport()
            seedTrackpadCamera(viewport: viewport)
            _ = applyTrackpadCameraDelta(trackpadPendingCameraDelta, viewport: viewport)
            trackpadPendingCameraDelta = .zero
        }

        resetTrackpadCameraMotion(clearCameraY: false)
    }

    private func performColumnNavigation(by delta: Int) {
        guard !transientSystemWindowIsActive() else {
            return
        }

        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false

        let now = CFAbsoluteTimeGetCurrent()
        let stepCount = abs(delta)
        let burstIsActive = columnNavigationBurstIsActive(at: now, stepCount: stepCount)
        let previousState = captureLayoutState()
        guard focusColumn(relativeOffset: delta) else {
            return
        }

        layoutVerificationGeneration &+= 1
        let newState = captureLayoutState()
        lastColumnNavigationAt = now
        lastColumnNavigationDirection = delta.signum()
        let duration = burstIsActive ? columnNavigationRetargetAnimationDuration : columnNavigationAnimationDuration
        markExpectedFocusedWindow(for: activeWindow(), duration: duration + 1.0)
        suppressFocusedWindowAdoption(for: duration + 0.5)
        debugLog("column navigation delta=\(delta) workspace=\(newState.activeWorkspace + 1) burst=\(burstIsActive)")

        if burstIsActive {
            if pendingColumnNavigationProjectionState == nil {
                pendingColumnNavigationProjectionState = previousState
            }
            suppressManualResizeNotifications(for: 0.25)
            flushColumnNavigationProjection(animated: true)
            return
        }

        projectLayout(
            focusActiveWindow: false,
            animated: previousState != newState,
            from: previousState,
            animationDuration: duration,
            layoutLockDelay: 0.04,
            prefocusActiveWindow: false,
            snapshotTiming: .deferred,
            verifyActiveLayout: false
        )
        scheduleColumnNavigationFocus(after: duration + 0.025)
    }

    private func perform(_ command: Command) {
        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        rescanWindows(adoptFocused: false)
        let previousState = captureLayoutState()
        var animated = false
        var frameAnimated = false
        var duration = keyboardAnimationDuration
        func runAnimatedChange(
            duration changeDuration: TimeInterval,
            frameChange: Bool = false,
            _ change: () -> Bool
        ) -> Bool {
            duration = changeDuration
            guard performAnimatedLayoutChange(from: previousState, change) else {
                return false
            }
            animated = true
            frameAnimated = frameAnimated || frameChange
            return true
        }

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            guard focusWorkspace(oneBasedIndex) else {
                return
            }
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
        case .workspaceUp:
            guard setActiveWorkspace(activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
        case .columnLeft:
            guard focusColumn(relativeOffset: -1) else {
                return
            }
            animated = true
        case .columnRight:
            guard focusColumn(relativeOffset: 1) else {
                return
            }
            animated = true
        case .columnFirst:
            guard focusColumn(at: 0) else {
                return
            }
            animated = true
        case .columnLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard focusColumn(at: workspace.columns.count - 1) else {
                return
            }
            animated = true
        case .moveColumnLeft:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnHorizontally(by: -1)
            }) else {
                return
            }
        case .moveColumnRight:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnHorizontally(by: 1)
            }) else {
                return
            }
        case .moveColumnToFirst:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumn(to: 0)
            }) else {
                return
            }
        case .moveColumnToLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumn(to: workspace.columns.count - 1)
            }) else {
                return
            }
        case .moveColumnToWorkspace(let oneBasedIndex):
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(oneBasedIndex: oneBasedIndex)
            }) else {
                return
            }
        case .moveColumnToWorkspaceDown:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(relativeOffset: 1)
            }) else {
                return
            }
        case .moveColumnToWorkspaceUp:
            guard runAnimatedChange(duration: moveColumnAnimationDuration, {
                moveActiveColumnToWorkspace(relativeOffset: -1)
            }) else {
                return
            }
        case .cycleWidthPresetBackward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleActiveWidthPreset(direction: -1)
            }) else {
                return
            }
        case .cycleWidthPresetForward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleActiveWidthPreset(direction: 1)
            }) else {
                return
            }
        case .nudgeWidthNarrower:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeActiveWidth(by: -0.1)
            }) else {
                return
            }
        case .nudgeWidthWider:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeActiveWidth(by: 0.1)
            }) else {
                return
            }
        case .cycleAllWidthPresetsBackward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleAllWidthPresets(direction: -1)
            }) else {
                return
            }
        case .cycleAllWidthPresetsForward:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                cycleAllWidthPresets(direction: 1)
            }) else {
                return
            }
        case .nudgeAllWidthsNarrower:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeAllWidths(by: -0.1)
            }) else {
                return
            }
        case .nudgeAllWidthsWider:
            guard runAnimatedChange(duration: widthAnimationDuration, frameChange: true, {
                nudgeAllWidths(by: 0.1)
            }) else {
                return
            }
        }

        let newState = captureLayoutState()
        projectLayout(
            focusActiveWindow: true,
            animated: animated && (previousState != newState || frameAnimated),
            from: previousState,
            animationDuration: duration
        )
    }

    private func performAnimatedLayoutChange(from state: LayoutState, _ change: () -> Bool) -> Bool {
        // LayoutState stores focus and camera state, not pre-mutation window order or width.
        seedPresentationFrames(from: state)
        guard change() else {
            presentationFrames.removeAll()
            return false
        }
        return true
    }

    private func focusWorkspace(_ oneBasedIndex: Int) -> Bool {
        guard !workspaces.isEmpty else {
            return false
        }

        let requestedIndex = min(max(oneBasedIndex - 1, 0), workspaces.count - 1)
        let targetIndex = workspaceAutoBackAndForth && requestedIndex == activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        guard setActiveWorkspace(targetIndex) else {
            return false
        }
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    private func focusPreviousWorkspace() -> Bool {
        guard let previousIndex = previousWorkspaceIndex(),
              previousIndex != activeWorkspace
        else {
            return false
        }

        setActiveWorkspace(previousIndex)
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    @discardableResult
    private func setActiveWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        guard !workspaces.isEmpty else {
            activeWorkspace = 0
            previousWorkspace = nil
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let currentWorkspace = activeWorkspaceObject()
        activeWorkspace = targetIndex
        if rememberPrevious {
            previousWorkspace = currentWorkspace
        }
        return true
    }

    private func previousWorkspaceIndex() -> Int? {
        guard let previousWorkspace else {
            return nil
        }

        return workspaces.firstIndex(where: { $0 === previousWorkspace })
    }

    private func focusColumn(at requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard targetIndex != workspace.activeColumn || workspace.scrollOffset != nil else {
            return false
        }

        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    private func focusColumn(relativeOffset delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(sourceIndex + delta, 0), workspace.columns.count - 1)
        guard targetIndex != sourceIndex else {
            return false
        }

        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    private func moveActiveColumnHorizontally(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        return moveActiveColumn(to: workspace.activeColumn + delta)
    }

    private func moveActiveColumn(to requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard sourceIndex != targetIndex else {
            return false
        }

        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    private func cycleActiveWidthPreset(direction: Int) -> Bool {
        guard let window = activeWindow() else {
            return false
        }

        guard let target = widthPreset(after: widthRatio(for: window), direction: direction) else {
            return false
        }

        return setActiveWindowWidthRatio(target)
    }

    private func cycleAllWidthPresets(direction: Int) -> Bool {
        guard let window = activeWindow(),
              let target = widthPreset(after: widthRatio(for: window), direction: direction)
        else {
            return false
        }

        return setAllWindowWidthRatios(target)
    }

    private func widthPreset(after current: CGFloat, direction: Int) -> CGFloat? {
        let presets = widthPresetRatios
        guard !presets.isEmpty else {
            return nil
        }

        if direction >= 0 {
            return presets.first(where: { $0 > current + 0.005 }) ?? presets[0]
        }

        return presets.last(where: { $0 < current - 0.005 }) ?? presets[presets.count - 1]
    }

    private func nudgeActiveWidth(by delta: CGFloat) -> Bool {
        guard let window = activeWindow() else {
            return false
        }
        return setActiveWindowWidthRatio(nudgedWidthRatio(from: widthRatio(for: window), by: delta))
    }

    private func nudgeAllWidths(by delta: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(nudgedWidthRatio(from: widthRatio(for: window), by: delta), for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    private func nudgedWidthRatio(from ratio: CGFloat, by delta: CGFloat) -> CGFloat {
        let nudgedRatio = ratio + delta
        if ratio <= 1.0, delta > 0 {
            return min(nudgedRatio, 1.0)
        }
        return nudgedRatio.clampedManualWidthRatio
    }

    private func setActiveWindowWidthRatio(_ ratio: CGFloat) -> Bool {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        guard setWidthRatio(ratio, for: window) else {
            return false
        }

        workspace.scrollOffset = nil
        return true
    }

    private func setAllWindowWidthRatios(_ ratio: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(ratio, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    private func setWidthRatio(_ ratio: CGFloat, for window: ManagedWindow) -> Bool {
        let oldRatio = widthRatio(for: window)
        let newRatio = ratio.clampedManualWidthRatio
        guard abs(oldRatio - newRatio) >= 0.005 else {
            return false
        }

        window.manualWidthRatio = newRatio
        return true
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(relativeOffset: Int) -> Bool {
        let targetIndex = activeWorkspace + relativeOffset
        return moveActiveColumnToWorkspace(zeroBasedIndex: targetIndex)
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(oneBasedIndex: Int) -> Bool {
        let zeroBased = max(0, oneBasedIndex - 1)
        return moveActiveColumnToWorkspace(zeroBasedIndex: zeroBased)
    }

    @discardableResult
    private func moveActiveColumnToWorkspace(zeroBasedIndex requestedIndex: Int) -> Bool {
        guard workspaces.indices.contains(activeWorkspace),
              let sourceWorkspace = activeWorkspaceObject(),
              !sourceWorkspace.columns.isEmpty
        else {
            return false
        }

        sourceWorkspace.clampFocus()
        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let targetWorkspace = workspaces[targetIndex]
        let movingWindow = sourceWorkspace.columns.remove(at: sourceWorkspace.activeColumn)
        sourceWorkspace.scrollOffset = nil
        sourceWorkspace.clampFocus()

        targetWorkspace.clampFocus()
        let insertionIndex = targetWorkspace.columns.isEmpty
            ? 0
            : min(targetWorkspace.activeColumn + 1, targetWorkspace.columns.count)
        targetWorkspace.columns.insert(movingWindow, at: insertionIndex)
        targetWorkspace.activeColumn = insertionIndex
        targetWorkspace.scrollOffset = nil

        setActiveWorkspace(targetIndex)
        ensureTrailingEmptyWorkspace()
        activeWorkspace = workspaces.firstIndex(where: { $0 === targetWorkspace }) ?? activeWorkspace
        return true
    }

    private func activeWorkspaceObject() -> Workspace? {
        guard workspaces.indices.contains(activeWorkspace) else {
            return nil
        }
        return workspaces[activeWorkspace]
    }

    private func captureLayoutState() -> LayoutState {
        LayoutState(
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            cameraY: trackpadCameraY
        )
    }

    private func seedPresentationFrames(from state: LayoutState) {
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        presentationFrames = Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0.frame) })
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        guard !reconcileExpectedFocusChange(pid: app.processIdentifier) else {
            return
        }
        guard !shouldSuppressFocusedWindowAdoption else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                  !reconcileExpectedFocusChange(pid: app.processIdentifier),
                  !shouldSuppressFocusedWindowAdoption
            else {
                return
            }
            rescanWindows(adoptFocused: false)
            adoptFocusedWindow(pid: app.processIdentifier, respectFocusSuppression: true)
        }
        adoptFocusedWindow(pid: app.processIdentifier, respectFocusSuppression: true)
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        scheduleRescan(after: 0.4, adoptFocused: true)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        scheduleRescan(after: 0.1, adoptFocused: false, projectLayoutAfter: true)
    }

    private func scheduleRescan(
        after delay: TimeInterval,
        adoptFocused: Bool,
        projectLayoutAfter: Bool = false
    ) {
        scheduledRescanAdoptFocused = scheduledRescanAdoptFocused || adoptFocused
        scheduledRescanProjectLayout = scheduledRescanProjectLayout || projectLayoutAfter
        cancelTimer(&scheduledRescanTimer)

        scheduledRescanTimer = makeMainTimer(
            deadline: .now() + delay,
            leeway: .milliseconds(25)
        ) { [weak self] in
            self?.runScheduledRescan()
        }
    }

    private func runScheduledRescan() {
        cancelTimer(&scheduledRescanTimer)

        let adoptFocused = scheduledRescanAdoptFocused
        let projectLayoutAfter = scheduledRescanProjectLayout
        scheduledRescanAdoptFocused = false
        scheduledRescanProjectLayout = false

        rescanWindows(adoptFocused: adoptFocused)
        if projectLayoutAfter {
            projectLayout(focusActiveWindow: false)
        }
    }

    private func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        let discovered = discoverWindows()
        var knownWindows = allWindows()
        var changed = false

        for window in knownWindows {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                if behavior(for: window) == .ignore {
                    setWindowAlpha(1, for: window.windowID)
                }
                removeWindow(window)
                knownWindows.removeAll { $0 === window }
                changed = true
            }
        }

        for found in discovered {
            if let existing = knownWindows.first(where: { sameWindow($0.element, found.element) }) {
                existing.title = found.title
                existing.appName = found.appName
                existing.bundleID = found.bundleID

                let shouldFloat = behavior(for: existing) == .float
                let isFloating = floatingWindows.contains(where: { $0 === existing })
                if shouldFloat != isFloating {
                    removeWindow(existing)
                    if shouldFloat {
                        insertFloatingWindow(existing, applyLayout: false)
                    } else {
                        insertNewWindow(existing, applyLayout: false, focusNewWindow: false)
                    }
                    changed = true
                }
            } else {
                if behavior(for: found) == .float {
                    insertFloatingWindow(found, applyLayout: false)
                } else {
                    insertNewWindow(found, applyLayout: false, focusNewWindow: false)
                }
                knownWindows.append(found)
                changed = true
            }
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        ensureTrailingEmptyWorkspace()
        pruneAppliedLayoutCache()

        if adoptFocused {
            let suppressFocusedAdoption = shouldSuppressFocusedWindowAdoption
            let adoptedFocusedWindow = suppressFocusedAdoption
                ? false
                : adoptFocusedWindow(
                    pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    applyLayout: false,
                    respectFocusSuppression: true
                )
            let restoredPersistentFocus = !suppressFocusedAdoption && !adoptedFocusedWindow
                ? restorePersistentFocusedWindow()
                : false
            if changed || restoredPersistentLayout || adoptedFocusedWindow || restoredPersistentFocus {
                projectLayout(
                    focusActiveWindow: restoredPersistentFocus,
                    layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08
                )
            }
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
    }

    private func discoverWindows() -> [ManagedWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let knownWindows = allWindows()
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else {
                continue
            }
            let pid = app.processIdentifier
            guard pid != currentPID else {
                continue
            }

            startObservingApp(pid: pid)

            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }

            for element in axWindows where isManageableWindow(element) || isKnownWindow(element, in: knownWindows) {
                let title = axString(element, kAXTitleAttribute) ?? ""
                let appName = app.localizedName ?? "pid \(pid)"
                let windowID = SkyLight.shared.windowID(for: element)
                let window = ManagedWindow(
                    element: element,
                    pid: pid,
                    windowID: windowID,
                    bundleID: app.bundleIdentifier,
                    appName: appName,
                    title: title
                )
                guard behavior(for: window) != .ignore else {
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    private func isManageableWindow(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

        if axBool(element, kAXMinimizedAttribute) == true {
            return false
        }

        guard let frame = axFrame(element), frame.width >= 120, frame.height >= 80 else {
            return false
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionError == .success && sizeError == .success && positionSettable.boolValue && sizeSettable.boolValue
    }

    private func isKnownWindow(_ element: AXUIElement, in knownWindows: [ManagedWindow]) -> Bool {
        knownWindows.contains { sameWindow($0.element, element) }
    }

    private func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)

        workspace.columns.insert(window, at: insertionIndex)
        workspace.activeColumn = insertionIndex
        workspace.scrollOffset = nil
        if let workspaceIndex = workspaces.firstIndex(where: { $0 === workspace }) {
            setActiveWorkspace(workspaceIndex, rememberPrevious: false)
        }
        ensureTrailingEmptyWorkspace()
        if applyLayout {
            projectLayout(focusActiveWindow: focusNewWindow)
        }
    }

    private func targetWorkspace(for window: ManagedWindow) -> Workspace {
        if let oneBased = rule(for: window)?.workspace {
            let index = max(0, oneBased - 1)
            ensureWorkspaceExists(index)
            return workspaces[index]
        }

        return activeWorkspaceObject() ?? workspaces[0]
    }

    private func ensureWorkspaceExists(_ index: Int) {
        while workspaces.count <= index {
            workspaces.append(Workspace())
        }
    }

    private func newWindowInsertionIndex(in workspace: Workspace, for window: ManagedWindow) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        switch rule(for: window)?.openPosition ?? newWindowPosition {
        case .beforeActive:
            return min(max(workspace.activeColumn, 0), workspace.columns.count)
        case .afterActive:
            return min(max(workspace.activeColumn + 1, 0), workspace.columns.count)
        case .end:
            return workspace.columns.count
        }
    }

    private func insertFloatingWindow(_ window: ManagedWindow, applyLayout: Bool = true) {
        if !floatingWindows.contains(where: { $0 === window }) {
            floatingWindows.append(window)
        }
        setWindowAlpha(1, for: window.windowID)
        setFloatingWindowLevel(for: window)
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    private func removeWindow(_ window: ManagedWindow) {
        invalidateAppliedLayoutCache(for: window)
        if let index = floatingWindows.firstIndex(where: { $0 === window }) {
            resetFloatingWindowLevel(for: window)
            floatingWindows.remove(at: index)
            return
        }

        for workspace in workspaces {
            if let index = workspace.columns.firstIndex(where: { $0 === window }) {
                workspace.columns.remove(at: index)
                if workspace.activeColumn >= index {
                    workspace.activeColumn = max(0, workspace.activeColumn - 1)
                }
                workspace.scrollOffset = nil
                workspace.clampFocus()
                break
            }
        }
        ensureTrailingEmptyWorkspace()
    }

    private func ensureTrailingEmptyWorkspace() {
        if workspaces.isEmpty {
            workspaces = [Workspace()]
            activeWorkspace = 0
            previousWorkspace = nil
            return
        }

        if !workspaces.last!.isEmpty {
            workspaces.append(Workspace())
        }

        if workspaces.count > 1 {
            for index in stride(from: workspaces.count - 2, through: 0, by: -1) {
                guard index != activeWorkspace, workspaces[index].isEmpty else {
                    continue
                }
                workspaces.remove(at: index)
                if activeWorkspace > index {
                    activeWorkspace -= 1
                }
            }
        }

        activeWorkspace = min(max(activeWorkspace, 0), workspaces.count - 1)
        for workspace in workspaces {
            workspace.clampFocus()
        }
    }

    private var animationDuration: TimeInterval {
        TimeInterval(config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240) / 1000
    }

    private var keyboardAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.keyboardAnimationMS ?? fallback) / 1000
    }

    private var columnNavigationAnimationDuration: TimeInterval {
        min(
            keyboardAnimationDuration,
            max(keyboardAnimationDuration * 0.65, 0.12)
        )
    }

    private var columnNavigationRetargetAnimationDuration: TimeInterval {
        min(columnNavigationAnimationDuration, max(keyboardAnimationDuration * 0.2, 0.045))
    }

    private func columnNavigationBurstIsActive(at now: CFAbsoluteTime, stepCount: Int) -> Bool {
        if animationTimer != nil
            || pendingColumnNavigationProjectionState != nil
            || columnNavigationFocusTimer != nil
            || stepCount > 1
        {
            return true
        }

        guard now - lastColumnNavigationAt < 0.18 else {
            return false
        }

        return lastColumnNavigationDirection != 0
    }

    private var hoverFocusAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.hoverFocusAnimationMS ?? fallback) / 1000
    }

    private var trackpadSettleAnimationDuration: TimeInterval {
        let milliseconds: Int
        if let navigationSpecific = config.trackpadNavigationSettleAnimationMS,
           navigationSpecific != (MiriConfig.fallback.trackpadNavigationSettleAnimationMS ?? 240)
        {
            milliseconds = navigationSpecific
        } else {
            milliseconds = config.trackpadSettleAnimationMS
                ?? config.trackpadNavigationSettleAnimationMS
                ?? config.animationDurationMS
                ?? MiriConfig.fallback.trackpadSettleAnimationMS
                ?? 240
        }
        return TimeInterval(milliseconds) / 1000
    }

    private var moveColumnAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.moveColumnAnimationMS ?? fallback) / 1000
    }

    private var widthAnimationDuration: TimeInterval {
        let fallback = config.keyboardAnimationMS
            ?? config.animationDurationMS
            ?? MiriConfig.fallback.widthAnimationMS
            ?? 280
        return TimeInterval(config.widthAnimationMS ?? fallback) / 1000
    }

    private var animationCurve: AnimationCurve {
        config.animationCurve ?? MiriConfig.fallback.animationCurve ?? .smooth
    }

    private var hoverFocusEnabled: Bool {
        (config.hoverToFocus ?? MiriConfig.fallback.hoverToFocus ?? true) && hoverFocusMode != .off
    }

    private var hoverFocusDelay: TimeInterval {
        TimeInterval(config.hoverFocusDelayMS ?? MiriConfig.fallback.hoverFocusDelayMS ?? 120) / 1000
    }

    private var hoverFocusMaxScrollRatio: CGFloat {
        config.hoverFocusRequiresVisibleRatio
            ?? config.hoverFocusMaxScrollRatio
            ?? MiriConfig.fallback.hoverFocusRequiresVisibleRatio
            ?? MiriConfig.fallback.hoverFocusMaxScrollRatio
            ?? 0.15
    }

    private var hoverFocusEdgeTriggerWidth: CGFloat {
        config.hoverFocusEdgeTriggerWidth ?? MiriConfig.fallback.hoverFocusEdgeTriggerWidth ?? 8
    }

    private var hoverFocusAfterTrackpad: TimeInterval {
        let milliseconds: Int
        if let navigationSpecific = config.trackpadNavigationHoverSuppressionMS,
           navigationSpecific != (MiriConfig.fallback.trackpadNavigationHoverSuppressionMS ?? 280)
        {
            milliseconds = navigationSpecific
        } else {
            milliseconds = config.hoverFocusAfterTrackpadMS
                ?? config.trackpadNavigationHoverSuppressionMS
                ?? MiriConfig.fallback.hoverFocusAfterTrackpadMS
                ?? 280
        }
        return TimeInterval(milliseconds) / 1000
    }

    private var hoverFocusMode: HoverFocusMode {
        config.hoverFocusMode ?? MiriConfig.fallback.hoverFocusMode ?? .edgeOrVisible
    }

    private var workspaceAutoBackAndForth: Bool {
        config.workspaceAutoBackAndForth ?? MiriConfig.fallback.workspaceAutoBackAndForth ?? true
    }

    private var focusAlignment: FocusAlignment {
        if let focusAlignment = config.focusAlignment {
            return focusAlignment
        }
        if let centerFocusedColumn = config.centerFocusedColumn {
            return centerFocusedColumn ? .smart : .left
        }
        if let focusAlignment = MiriConfig.fallback.focusAlignment {
            return focusAlignment
        }
        return (config.centerFocusedColumn ?? MiriConfig.fallback.centerFocusedColumn ?? true) ? .smart : .left
    }

    private var newWindowPosition: NewWindowPosition {
        config.newWindowPosition ?? MiriConfig.fallback.newWindowPosition ?? .afterActive
    }

    private var innerGap: CGFloat {
        config.innerGap ?? MiriConfig.fallback.innerGap ?? 0
    }

    private var outerGap: CGFloat {
        config.outerGap ?? MiriConfig.fallback.outerGap ?? 0
    }

    private var parkedSliverWidth: CGFloat {
        config.parkedSliverWidth ?? MiriConfig.fallback.parkedSliverWidth ?? 1
    }

    private var trackpadNavigationEnabled: Bool {
        config.trackpadNavigation ?? MiriConfig.fallback.trackpadNavigation ?? true
    }

    private var trackpadNavigationFingers: Int {
        config.trackpadNavigationFingers ?? MiriConfig.fallback.trackpadNavigationFingers ?? 3
    }

    private var trackpadNavigationSensitivity: CGFloat {
        config.trackpadNavigationSensitivity ?? MiriConfig.fallback.trackpadNavigationSensitivity ?? 1.6
    }

    private var trackpadNavigationDeceleration: CGFloat {
        config.trackpadNavigationDeceleration ?? MiriConfig.fallback.trackpadNavigationDeceleration ?? 5.5
    }

    private var trackpadNavigationMomentumMinVelocity: CGFloat {
        config.trackpadNavigationMomentumMinVelocity
            ?? MiriConfig.fallback.trackpadNavigationMomentumMinVelocity
            ?? 80
    }

    private var trackpadNavigationVelocityGain: CGFloat {
        config.trackpadNavigationVelocityGain ?? MiriConfig.fallback.trackpadNavigationVelocityGain ?? 1.35
    }

    private var trackpadNavigationSnap: TrackpadNavigationSnap {
        config.trackpadNavigationSnap ?? MiriConfig.fallback.trackpadNavigationSnap ?? .nearestColumn
    }

    private var trackpadNavigationInvertX: Bool {
        config.trackpadNavigationInvertX ?? MiriConfig.fallback.trackpadNavigationInvertX ?? false
    }

    private var trackpadNavigationInvertY: Bool {
        config.trackpadNavigationInvertY ?? MiriConfig.fallback.trackpadNavigationInvertY ?? false
    }

    private var trackpadNavigationSettings: TrackpadNavigationSettings {
        TrackpadNavigationSettings(
            enabled: trackpadNavigationEnabled,
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY
        )
    }

    private var widthPresetRatios: [CGFloat] {
        config.presetWidthRatios ?? MiriConfig.fallback.presetWidthRatios ?? [0.5, 0.67, 0.8, 1.0]
    }

    private var rescanInterval: TimeInterval {
        TimeInterval(config.rescanIntervalMS ?? MiriConfig.fallback.rescanIntervalMS ?? 1000) / 1000
    }

    private var restoreOnExit: Bool {
        config.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true
    }

    private var hideMethod: HideMethod {
        config.hideMethod ?? MiriConfig.fallback.hideMethod ?? .skyLightAlpha
    }

    private var debugLogging: Bool {
        config.debugLogging ?? MiriConfig.fallback.debugLogging ?? false
    }

    private var shouldSuppressFocusedWindowAdoption: Bool {
        isApplyingLayout
            || animationTimer != nil
            || expectedFocusedWindowID() != nil
            || CFAbsoluteTimeGetCurrent() < focusedWindowAdoptionSuppressedUntil
    }

    private func suppressFocusedWindowAdoption(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }

        let until = CFAbsoluteTimeGetCurrent() + duration
        focusedWindowAdoptionSuppressedUntil = max(focusedWindowAdoptionSuppressedUntil, until)
    }

    private func markExpectedFocusedWindow(for window: ManagedWindow?, duration: TimeInterval) {
        guard let window else {
            expectedFocusedWindow = nil
            expectedFocusedWindowUntil = 0
            return
        }

        expectedFocusedWindow = ObjectIdentifier(window)
        expectedFocusedWindowUntil = max(expectedFocusedWindowUntil, CFAbsoluteTimeGetCurrent() + max(duration, 0.25))
    }

    private func expectedFocusedWindowID() -> ObjectIdentifier? {
        guard let expectedFocusedWindow else {
            return nil
        }

        guard CFAbsoluteTimeGetCurrent() <= expectedFocusedWindowUntil else {
            self.expectedFocusedWindow = nil
            expectedFocusedWindowUntil = 0
            return nil
        }

        return expectedFocusedWindow
    }

    private func settleExpectedFocusedWindow(if window: ManagedWindow) {
        guard expectedFocusedWindow == ObjectIdentifier(window) else {
            return
        }

        expectedFocusedWindowUntil = max(expectedFocusedWindowUntil, CFAbsoluteTimeGetCurrent() + 0.75)
    }

    private func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        animationDuration: TimeInterval? = nil,
        layoutLockDelay: TimeInterval = 0.08,
        prefocusActiveWindow: Bool = false,
        snapshotTiming: LayoutSnapshotTiming = .immediate,
        verifyActiveLayout: Bool = true
    ) {
        let viewport = currentViewport()
        writeLayoutSnapshots(viewport: viewport, timing: animated ? .deferred : snapshotTiming)

        let targetState = captureLayoutState()
        updateStatusItem()
        debugLog("layout workspace=\(targetState.activeWorkspace + 1) tiled=\(tiledWindows().count) floating=\(floatingWindows.count) animated=\(animated)")
        let duration = animationDuration ?? self.animationDuration
        suppressManualResizeNotifications(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        if focusActiveWindow {
            markExpectedFocusedWindow(
                for: activeWindow(),
                duration: (animated ? duration : 0) + max(layoutLockDelay, 0.25) + 0.75
            )
            suppressFocusedWindowAdoption(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        }
        if animated, duration > 0, let previousState {
            animateLayout(
                from: previousState,
                to: targetState,
                viewport: viewport,
                focusActiveWindow: focusActiveWindow,
                prefocusActiveWindow: prefocusActiveWindow,
                duration: duration,
                verifyActiveLayout: verifyActiveLayout
            )
            return
        }

        stopAnimation(clearPresentation: true)
        beginLayoutLock()
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow, forceFocusedFrame: focusActiveWindow)
        if verifyActiveLayout {
            scheduleActiveLayoutVerification(
                focusActiveWindow: focusActiveWindow,
                layoutLockDelay: layoutLockDelay
            )
        }
        restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
        releaseLayoutLock(after: layoutLockDelay)
    }

    private func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let stateActiveWorkspace = min(max(state.activeWorkspace, 0), max(workspaces.count - 1, 0))
        let cameraY = state.cameraY ?? CGFloat(stateActiveWorkspace) * viewport.height
        let cameraWorkspace = trackpadCameraWorkspaceIndex(cameraY: cameraY, viewport: viewport)
        var layout: [LayoutItem] = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let scrollOffset = scrollOffset(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let strip = stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: activeColumn,
                scrollOffset: scrollOffset
            )
            let rowOffset = CGFloat(workspaceIndex) * viewport.height - cameraY

            for (columnIndex, window) in workspace.columns.enumerated() {
                let frame: CGRect
                var projected = strip[columnIndex]
                projected.origin.y += rowOffset
                projected = visualFrame(projected, viewport: viewport)

                let visible = projected.intersects(viewport)
                if visible || !parkHidden {
                    frame = projected
                } else if workspaceIndex == cameraWorkspace {
                    frame = parkedFrame(for: window, viewport: viewport, beforeActive: columnIndex < activeColumn)
                } else {
                    frame = parkedFrame(
                        for: window,
                        viewport: viewport,
                        beforeActive: CGFloat(workspaceIndex) * viewport.height < cameraY
                    )
                }

                layout.append(LayoutItem(window: window, frame: frame, visible: visible))
            }
        }

        return layout
    }

    private func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    private func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    private func trackpadCameraWorkspaceIndex(cameraY: CGFloat, viewport: CGRect) -> Int {
        guard viewport.height > 0, !workspaces.isEmpty else {
            return 0
        }

        return min(max(Int(round(cameraY / viewport.height)), 0), workspaces.count - 1)
    }

    private func applyLayout(
        _ layout: [LayoutItem],
        focusActiveWindow: Bool,
        verifyFocus: Bool = true,
        focusDelay: TimeInterval = 0,
        forceFocusedFrame: Bool = false
    ) {
        let focusedWindow = focusActiveWindow ? activeWindow() : nil
        if let focusedWindow, let focusedItem = layout.first(where: { $0.window === focusedWindow }) {
            applyFrame(focusedItem.frame, to: focusedWindow, force: forceFocusedFrame)
            setWindowAlpha(1, for: focusedWindow.windowID)
        }

        for item in layout where item.visible {
            if let focusedWindow, item.window === focusedWindow {
                continue
            }
            applyFrame(item.frame, to: item.window)
            setWindowAlpha(1, for: item.window.windowID)
        }

        for item in layout where !item.visible {
            applyFrame(item.frame, to: item.window)
            setWindowAlpha(0, for: item.window.windowID)
        }

        if let focusedWindow {
            requestFocus(focusedWindow, verify: verifyFocus, delay: focusDelay)
        }
    }

    private func restoreFloatingVisibility(raise: Bool = false, deferred: Bool = false) {
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
            setFloatingWindowLevel(for: window)
            if raise {
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            }
        }

        if raise && deferred {
            scheduleFloatingWindowRaise()
        }
    }

    private func setFloatingWindowLevel(for window: ManagedWindow) {
        setWindowLevel(floatingWindowLevel, for: window.windowID)
    }

    private func resetFloatingWindowLevel(for window: ManagedWindow) {
        setWindowLevel(normalWindowLevel, for: window.windowID)
    }

    private func scheduleFloatingWindowRaise() {
        guard !floatingWindows.isEmpty else {
            return
        }

        floatingRaiseGeneration &+= 1
        let generation = floatingRaiseGeneration
        for delay in [0.04, 0.16, 0.34] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      generation == floatingRaiseGeneration
                else {
                    return
                }
                restoreFloatingVisibility(raise: true)
            }
        }
    }

    private func transientSystemWindowIsActive(forceRefresh: Bool = false) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if !forceRefresh, now - transientWindowStateCheckedAt < 0.25 {
            return transientWindowActive
        }

        transientWindowStateCheckedAt = now
        let activeTransientWindows = transientSystemWindows()
        recoverTransientSystemWindows(activeTransientWindows)
        transientWindowActive = !activeTransientWindows.isEmpty
        return transientWindowActive
    }

    private func transientSystemWindows() -> [TransientSystemWindow] {
        transientCheckApplications.compactMap { app in
            guard let window = focusedWindow(for: app),
                  isTransientSystemWindow(window, app: app)
            else {
                return nil
            }
            return TransientSystemWindow(element: window)
        }
    }

    @discardableResult
    private func recoverTransientSystemWindows(_ windows: [TransientSystemWindow]) -> Bool {
        guard !windows.isEmpty else {
            return false
        }

        let viewport = currentViewport()
        var moved = false
        for transient in windows {
            setWindowAlpha(1, for: SkyLight.shared.windowID(for: transient.element))
            if let frame = axFrame(transient.element), transientFrameNeedsRecovery(frame, viewport: viewport) {
                setAXPosition(centeredOrigin(for: frame, in: viewport), for: transient.element)
                moved = true
            }
            AXUIElementPerformAction(transient.element, kAXRaiseAction as CFString)
        }
        return moved
    }

    private func transientFrameNeedsRecovery(_ frame: CGRect, viewport: CGRect) -> Bool {
        !frame.intersects(viewport)
            || frame.midX < viewport.minX
            || frame.midX > viewport.maxX
            || frame.midY < viewport.minY
            || frame.midY > viewport.maxY
    }

    private func centeredOrigin(for frame: CGRect, in viewport: CGRect) -> CGPoint {
        CGPoint(
            x: viewport.midX - frame.width / 2,
            y: viewport.midY - frame.height / 2
        )
    }

    private var transientCheckApplications: [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            apps.append(frontmostApplication)
        }
        for app in NSWorkspace.shared.runningApplications where app.isActive {
            if !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                apps.append(app)
            }
        }
        for panelService in openAndSavePanelServices(matchingAnyHostIn: apps) {
            if !apps.contains(where: { $0.processIdentifier == panelService.processIdentifier }) {
                apps.append(panelService)
            }
        }
        return apps
    }

    private func openAndSavePanelServices(matchingAnyHostIn hosts: [NSRunningApplication]) -> [NSRunningApplication] {
        let hostNames = hosts.compactMap(\.localizedName)
        guard !hostNames.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.filter { app in
            guard isOpenAndSavePanelService(app),
                  let name = app.localizedName
            else {
                return false
            }
            return hostNames.contains { name.contains("(\($0))") }
        }
    }

    private func isOpenAndSavePanelService(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
    }

    private func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func isTransientSystemWindow(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        if role == kAXSheetRole || role == "AXSheet" || role == "AXDialog" {
            return true
        }
        if subrole == "AXSystemDialog" || subrole == "AXDialog" {
            return true
        }
        return isOpenAndSavePanelService(app)
    }

    private func setWindowAlpha(_ alpha: Float, for windowID: UInt32?) {
        guard hideMethod == .skyLightAlpha else {
            return
        }
        if let windowID {
            if let previous = appliedAlphas[windowID], abs(previous - alpha) < 0.001 {
                return
            }
            SkyLight.shared.setAlpha(alpha, for: windowID)
            appliedAlphas[windowID] = alpha
            return
        }
        SkyLight.shared.setAlpha(alpha, for: windowID)
    }

    private func setWindowLevel(_ level: Int32, for windowID: UInt32?) {
        guard let windowID, SkyLight.shared.canSetWindowLevel else {
            return
        }

        if appliedWindowLevels[windowID] == level {
            return
        }

        guard SkyLight.shared.setLevel(level, for: windowID) else {
            return
        }

        if level == normalWindowLevel {
            appliedWindowLevels.removeValue(forKey: windowID)
        } else {
            appliedWindowLevels[windowID] = level
        }
    }

    private func clearAppliedLayoutCache() {
        appliedFrames.removeAll()
        appliedAlphas.removeAll()
        appliedWindowLevels.removeAll()
    }

    private func invalidateAppliedLayoutCache(for window: ManagedWindow) {
        appliedFrames.removeValue(forKey: ObjectIdentifier(window))
        if let windowID = window.windowID {
            appliedAlphas.removeValue(forKey: windowID)
            appliedWindowLevels.removeValue(forKey: windowID)
        }
    }

    private func invalidateAppliedLayoutCache(for element: AXUIElement) {
        guard let window = allWindows().first(where: { sameWindow($0.element, element) }) else {
            return
        }
        invalidateAppliedLayoutCache(for: window)
    }

    private func pruneAppliedLayoutCache() {
        let windows = allWindows()
        let liveWindowIDs = Set(windows.map(ObjectIdentifier.init))
        appliedFrames = appliedFrames.filter { liveWindowIDs.contains($0.key) }

        let liveSkyLightIDs = Set(windows.compactMap(\.windowID))
        appliedAlphas = appliedAlphas.filter { liveSkyLightIDs.contains($0.key) }
        appliedWindowLevels = appliedWindowLevels.filter { liveSkyLightIDs.contains($0.key) }
    }

    private func debugLog(_ message: String) {
        guard debugLogging else {
            return
        }
        print("miri: \(message)")
    }

    private func hoverFocusTarget(
        at point: CGPoint
    ) -> (window: ManagedWindow, workspaceIndex: Int, columnIndex: Int, immediate: Bool)? {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return nil
        }

        let viewport = currentViewport()
        guard viewportContains(point, viewport: viewport) else {
            return nil
        }

        let state = captureLayoutState()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        for item in layout where item.visible && item.frame.contains(point) {
            guard hoverToFocusAllowed(for: item.window) else {
                continue
            }
            guard let loc = location(of: item.window.element), loc.workspace == activeWorkspace else {
                continue
            }
            if loc.column == workspace.activeColumn {
                return nil
            }
            let immediate = hoverFocusMode == .edgeOrVisible
                && hoverFocusEdgeTrigger(
                    targetColumn: loc.column,
                    activeColumn: workspace.activeColumn,
                    point: point,
                    viewport: viewport
                )
            guard immediate || hoverFocusCanScroll(
                toColumn: loc.column,
                in: workspace,
                workspaceIndex: loc.workspace,
                state: state,
                viewport: viewport,
                targetFrame: item.frame,
                point: point
            ) else {
                continue
            }
            return (item.window, loc.workspace, loc.column, immediate)
        }

        return nil
    }

    private func viewportContains(_ point: CGPoint, viewport: CGRect) -> Bool {
        point.x >= viewport.minX
            && point.x <= viewport.maxX
            && point.y >= viewport.minY
            && point.y <= viewport.maxY
    }

    private func visualFrame(_ frame: CGRect, viewport: CGRect) -> CGRect {
        guard innerGap > 0 else {
            return frame
        }

        let inset = min(innerGap / 2, frame.width / 3, frame.height / 3)
        return frame.insetBy(dx: inset, dy: inset)
    }

    private func insetViewport(_ viewport: CGRect, by inset: CGFloat) -> CGRect {
        guard inset > 0 else {
            return viewport
        }

        let safeInset = min(inset, viewport.width / 3, viewport.height / 3)
        return viewport.insetBy(dx: safeInset, dy: safeInset)
    }

    private func hoverFocusEdgeTrigger(
        targetColumn: Int,
        activeColumn: Int,
        point: CGPoint,
        viewport: CGRect
    ) -> Bool {
        if targetColumn > activeColumn {
            return point.x >= viewport.maxX - hoverFocusEdgeTriggerWidth
        }
        if targetColumn < activeColumn {
            return point.x <= viewport.minX + hoverFocusEdgeTriggerWidth
        }
        return false
    }

    private func hoverFocusCanScroll(
        toColumn targetColumn: Int,
        in workspace: Workspace,
        workspaceIndex: Int,
        state: LayoutState,
        viewport: CGRect,
        targetFrame: CGRect,
        point: CGPoint
    ) -> Bool {
        guard viewport.width > 0 else {
            return false
        }

        guard workspace.columns.indices.contains(targetColumn) else {
            return false
        }

        let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
        let requiredDepth = viewport.width * hoverFocusMaxScrollRatio
        guard requiredDepth > 0 else {
            return false
        }

        let visibleTargetFrame = targetFrame.intersection(viewport)
        guard !visibleTargetFrame.isNull else {
            return false
        }

        if targetColumn > activeColumn {
            return point.x - visibleTargetFrame.minX >= requiredDepth
        }
        if targetColumn < activeColumn {
            return visibleTargetFrame.maxX - point.x >= requiredDepth
        }
        return false
    }

    private func scheduleHoverFocus(for window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        let id = ObjectIdentifier(window)
        if hoverFocusTarget == id {
            return
        }

        cancelHoverFocus()
        hoverFocusTarget = id

        hoverFocusTimer = makeMainTimer(
            deadline: .now() + hoverFocusDelay,
            leeway: .milliseconds(20)
        ) { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            performHoverFocus(window: window, workspaceIndex: workspaceIndex, columnIndex: columnIndex)
        }
    }

    private func performHoverFocus(window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        cancelTimer(&hoverFocusTimer)
        hoverFocusTarget = nil

        guard hoverFocusEnabled,
              manualResizeElement == nil,
              animationTimer == nil,
              workspaces.indices.contains(workspaceIndex),
              workspaces[workspaceIndex].columns.indices.contains(columnIndex),
              workspaces[workspaceIndex].columns[columnIndex] === window
        else {
            return
        }

        let workspace = workspaces[workspaceIndex]
        guard activeWorkspace != workspaceIndex || workspace.activeColumn != columnIndex else {
            return
        }

        freezeTrackpadCameraForTransition()
        let previousState = captureLayoutState()
        trackpadCameraY = nil
        setActiveWorkspace(workspaceIndex)
        workspace.activeColumn = columnIndex
        workspace.scrollOffset = nil
        let newState = captureLayoutState()
        hoverFocusRequiresRearm = true
        projectLayout(
            focusActiveWindow: true,
            animated: previousState != newState,
            from: previousState,
            animationDuration: hoverFocusAnimationDuration
        )
    }

    private func cancelHoverFocus() {
        cancelTimer(&hoverFocusTimer)
        hoverFocusTarget = nil
    }

    private func shouldSuppressHoverFocusUntilRearmed(at point: CGPoint) -> Bool {
        guard hoverFocusRequiresRearm else {
            return false
        }

        if hoverFocusTarget(at: point) == nil {
            hoverFocusRequiresRearm = false
            return false
        }

        return true
    }

    private func animateLayout(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        prefocusActiveWindow: Bool,
        duration: TimeInterval,
        verifyActiveLayout: Bool
    ) {
        stopAnimation(clearPresentation: false)
        let generation = nextAnimationGeneration()
        beginLayoutLock()

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys)

        let motions = windowIDs.compactMap { id -> WindowMotion? in
            guard let window = startByWindow[id]?.window ?? targetByWindow[id]?.window else {
                return nil
            }
            let startFrame = presentationFrames[id] ?? startByWindow[id]?.frame ?? targetByWindow[id]?.frame
            let endFrame = targetByWindow[id]?.frame ?? startFrame
            guard let startFrame, let endFrame else {
                return nil
            }
            let participates = startFrame.intersects(viewport) || endFrame.intersects(viewport)
            let sizeStable = abs(startFrame.width - endFrame.width) < 0.5
                && abs(startFrame.height - endFrame.height) < 0.5
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                startsVisible: startByWindow[id]?.visible ?? false,
                endsVisible: targetByWindow[id]?.visible ?? false,
                participates: participates,
                sizeStable: sizeStable
            )
        }

        guard !motions.isEmpty else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow, forceFocusedFrame: focusActiveWindow)
            if verifyActiveLayout {
                scheduleActiveLayoutVerification(focusActiveWindow: focusActiveWindow)
            }
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]
        for motion in motions where motion.participates {
            applyFrame(motion.startFrame, to: motion)
            nextPresentationFrames[ObjectIdentifier(motion.window)] = motion.startFrame
        }
        presentationFrames = nextPresentationFrames

        primeAnimationVisibility(for: motions)
        if prefocusActiveWindow, focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow, verify: false, reveal: false)
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        animationTimer = makeMainTimer(
            deadline: .now() + frameTimerInterval,
            repeating: frameTimerInterval,
            leeway: frameTimerLeeway
        ) { [weak self] in
            guard let self else {
                return
            }
            guard generation == animationGeneration else {
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - startedAt
            let linearProgress = min(max(elapsed / duration, 0), 1)
            let easedProgress = softSettleCurve(CGFloat(linearProgress))
            let isFinalFrame = linearProgress >= 1
            applyAnimationFrame(
                motions,
                progress: easedProgress,
                viewport: viewport
            )
            restoreFloatingVisibility()

            if isFinalFrame {
                cancelTimer(&animationTimer)
                animationGeneration &+= 1
                applyLayout(
                    finalLayout,
                    focusActiveWindow: focusActiveWindow,
                    focusDelay: focusActiveWindow ? 0.035 : 0,
                    forceFocusedFrame: focusActiveWindow
                )
                if verifyActiveLayout {
                    scheduleActiveLayoutVerification(focusActiveWindow: focusActiveWindow)
                }
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
        }
    }

    private func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }

    private func applyAnimationFrame(
        _ motions: [WindowMotion],
        progress: CGFloat,
        viewport: CGRect
    ) {
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for motion in motions {
            guard motion.participates else {
                continue
            }

            let frame = interpolate(from: motion.startFrame, to: motion.endFrame, progress: progress)
            nextPresentationFrames[ObjectIdentifier(motion.window)] = frame
            applyFrame(frame, to: motion)
            applyAnimationVisibility(for: motion, progress: progress)
        }

        presentationFrames = nextPresentationFrames
    }

    private func primeAnimationVisibility(for motions: [WindowMotion]) {
        for motion in motions {
            let alpha: Float = motion.participates && motion.startsVisible ? 1 : 0
            setWindowAlpha(alpha, for: motion.window.windowID)
        }
    }

    private func applyAnimationVisibility(for motion: WindowMotion, progress: CGFloat) {
        guard motion.participates else {
            return
        }

        if motion.startsVisible {
            setWindowAlpha(1, for: motion.window.windowID)
            return
        }

        let shouldReveal = motion.endsVisible && progress >= 0.08
        setWindowAlpha(shouldReveal ? 1 : 0, for: motion.window.windowID)
    }

    private func applyFrame(_ frame: CGRect, to motion: WindowMotion) {
        applyFrame(frame, to: motion.window, sizeStable: motion.sizeStable)
    }

    private func applyFrame(
        _ frame: CGRect,
        to window: ManagedWindow,
        sizeStable: Bool = false,
        force: Bool = false
    ) {
        let id = ObjectIdentifier(window)
        if !force,
           let previous = appliedFrames[id],
           framesApproximatelyEqual(previous, frame, tolerance: 0.5)
        {
            return
        }

        let succeeded: Bool
        if !force,
           sizeStable,
           let previous = appliedFrames[id],
           abs(previous.width - frame.width) < 0.5,
           abs(previous.height - frame.height) < 0.5
        {
            succeeded = setAXPosition(frame.origin, for: window.element)
        } else {
            succeeded = setAXFrame(frame, for: window.element)
        }

        if succeeded {
            appliedFrames[id] = frame
        }
    }

    private func stopAnimation(clearPresentation: Bool) {
        animationGeneration &+= 1
        cancelTimer(&animationTimer)
        if clearPresentation {
            presentationFrames.removeAll()
        }
        layoutLockGeneration &+= 1
        isApplyingLayout = false
    }

    private func nextAnimationGeneration() -> UInt64 {
        animationGeneration &+= 1
        return animationGeneration
    }

    private func beginLayoutLock() {
        layoutLockGeneration &+= 1
        isApplyingLayout = true
    }

    private func releaseLayoutLock(after delay: TimeInterval = 0.08) {
        let generation = layoutLockGeneration
        guard delay > 0 else {
            if generation == layoutLockGeneration {
                isApplyingLayout = false
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == layoutLockGeneration,
                  animationTimer == nil
            else {
                return
            }
            isApplyingLayout = false
        }
    }

    private func softSettleCurve(_ progress: CGFloat) -> CGFloat {
        switch animationCurve {
        case .linear:
            return progress
        case .snappy:
            return cubicBezier(progress, x1: 0.2, y1: 0.0, x2: 0.0, y2: 1.0)
        case .smooth:
            return cubicBezier(progress, x1: 0.16, y1: 0.0, x2: 0.18, y2: 1.0)
        }
    }

    private func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
        guard progress > 0 else {
            return 0
        }
        guard progress < 1 else {
            return 1
        }

        var t = progress
        for _ in 0..<5 {
            let x = bezierCoordinate(t, p1: x1, p2: x2) - progress
            let derivative = bezierDerivative(t, p1: x1, p2: x2)
            if abs(derivative) < 0.0001 {
                break
            }
            t = min(max(t - x / derivative, 0), 1)
        }

        return bezierCoordinate(t, p1: y1, p2: y2)
    }

    private func bezierCoordinate(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t
    }

    private func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * p1
            + 6 * inverse * t * (p2 - p1)
            + 3 * t * t * (1 - p2)
    }

    private func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    private func stripFrames(
        for workspace: Workspace,
        viewport: CGRect,
        activeColumn: Int,
        scrollOffset preferredScrollOffset: CGFloat?
    ) -> [CGRect] {
        guard !workspace.columns.isEmpty else {
            return []
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let scrollOffset = preferredScrollOffset ?? defaultScrollOffset(
            metrics: metrics,
            activeColumn: activeColumn,
            viewport: viewport
        )
        return workspace.columns.indices.map { index in
            CGRect(
                x: viewport.minX + metrics.origins[index] - scrollOffset,
                y: viewport.minY,
                width: metrics.widths[index],
                height: viewport.height
            )
        }
    }

    private func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
        var virtualX: CGFloat = 0
        var origins: [CGFloat] = []
        var widths: [CGFloat] = []

        for window in workspace.columns {
            origins.append(virtualX)
            let width = viewport.width * widthRatio(for: window)
            widths.append(width)
            virtualX += width
        }

        return (origins, widths)
    }

    private func horizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        if let scrollOffset = workspace.scrollOffset {
            return min(max(scrollOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let activeColumn = min(max(workspace.activeColumn, 0), max(workspace.columns.count - 1, 0))
        return defaultScrollOffset(metrics: metrics, activeColumn: activeColumn, viewport: viewport)
    }

    private func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let contentWidth = zip(metrics.origins, metrics.widths)
            .map { $0.0 + $0.1 }
            .max() ?? viewport.width
        let lastColumnOffset = defaultScrollOffset(
            metrics: metrics,
            activeColumn: workspace.columns.count - 1,
            viewport: viewport
        )
        return max(0, contentWidth - viewport.width, lastColumnOffset)
    }

    private func closestColumn(to scrollOffset: CGFloat, in workspace: Workspace, viewport: CGRect) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let cameraCenter = scrollOffset + viewport.width / 2
        var closestIndex = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for index in workspace.columns.indices {
            guard metrics.origins.indices.contains(index), metrics.widths.indices.contains(index) else {
                continue
            }

            let columnCenter = metrics.origins[index] + metrics.widths[index] / 2
            let distance = abs(columnCenter - cameraCenter)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        return closestIndex
    }

    private func mostVisibleColumn(in workspace: Workspace, viewport: CGRect, scrollOffset: CGFloat) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        let frames = stripFrames(
            for: workspace,
            viewport: viewport,
            activeColumn: workspace.activeColumn,
            scrollOffset: scrollOffset
        )
        var bestIndex = closestColumn(to: scrollOffset, in: workspace, viewport: viewport)
        var bestVisibleWidth: CGFloat = 0
        for index in frames.indices {
            let visibleFrame = visualFrame(frames[index], viewport: viewport).intersection(viewport)
            let visibleWidth = visibleFrame.isNull ? 0 : visibleFrame.width
            if visibleWidth > bestVisibleWidth {
                bestVisibleWidth = visibleWidth
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func defaultScrollOffset(
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        activeColumn: Int,
        viewport: CGRect
    ) -> CGFloat {
        guard metrics.origins.indices.contains(activeColumn),
              metrics.widths.indices.contains(activeColumn)
        else {
            return 0
        }

        switch focusAlignment {
        case .left:
            return metrics.origins[activeColumn]
        case .smart where activeColumn == 0:
            return metrics.origins.indices.contains(activeColumn) ? metrics.origins[activeColumn] : 0
        case .smart, .center:
            let activeCenter = metrics.origins[activeColumn] + metrics.widths[activeColumn] / 2
            return max(0, activeCenter - viewport.width / 2)
        }
    }

    private func parkedFrame(for window: ManagedWindow, viewport: CGRect, beforeActive: Bool) -> CGRect {
        let width = viewport.width * widthRatio(for: window)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height)
        frame.origin.x = beforeActive
            ? viewport.minX - width + parkedSliverWidth
            : viewport.maxX - parkedSliverWidth
        return frame
    }

    private func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        for rule in config.rules where rule.matches(window) {
            if let widthRatio = rule.widthRatio {
                return widthRatio.clampedWidthRatio
            }
        }
        return config.defaultWidthRatio.clampedWidthRatio
    }

    private func behavior(for window: ManagedWindow) -> WindowBehavior {
        for rule in config.rules where rule.matches(window) {
            if let behavior = rule.behavior {
                return behavior
            }
        }
        return .tile
    }

    private func rule(for window: ManagedWindow) -> WindowRule? {
        config.rules.first { $0.matches(window) }
    }

    private func hoverToFocusAllowed(for window: ManagedWindow) -> Bool {
        rule(for: window)?.hoverToFocus ?? true
    }

    private var trackpadNavigationAllowedForActiveWindow: Bool {
        guard let window = activeWindow() else {
            return true
        }
        return rule(for: window)?.trackpadNavigation ?? true
    }

    private func currentViewport() -> CGRect {
        guard let screen = NSScreen.main else {
            return insetViewport(CGDisplayBounds(CGMainDisplayID()), by: outerGap)
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        let viewport = CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
        return insetViewport(viewport, by: outerGap)
    }

    private func requestFocus(_ window: ManagedWindow, verify: Bool, delay: TimeInterval) {
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        let windowID = ObjectIdentifier(window)

        guard delay > 0 else {
            focus(window, verify: verify)
            return
        }

        suppressFocusedWindowAdoption(for: delay + 0.35)
        markExpectedFocusedWindow(for: window, duration: delay + 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  generation == focusRequestGeneration,
                  let active = activeWindow(),
                  ObjectIdentifier(active) == windowID,
                  animationTimer == nil
            else {
                return
            }

            focus(active, verify: verify)
        }
    }

    private func focus(_ window: ManagedWindow, verify: Bool = true, reveal: Bool = true) {
        focusRequestGeneration &+= 1
        suppressFocusedWindowAdoption(for: 0.25)
        markExpectedFocusedWindow(for: window, duration: 1.0)
        if reveal {
            setWindowAlpha(1, for: window.windowID)
        }
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window.element)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        restoreFloatingVisibility(raise: true, deferred: true)
        if verify {
            scheduleFocusVerification(for: window)
        }
    }

    private func scheduleFocusVerification(for window: ManagedWindow) {
        focusVerificationGeneration &+= 1
        let generation = focusVerificationGeneration
        let windowID = ObjectIdentifier(window)
        for delay in [0.02, 0.08, 0.18, 0.36] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyFocusedWindow(windowID: windowID, generation: generation)
            }
        }
    }

    private func verifyFocusedWindow(windowID: ObjectIdentifier, generation: UInt64) {
        guard generation == focusVerificationGeneration,
              let window = activeWindow(),
              ObjectIdentifier(window) == windowID,
              animationTimer == nil
        else {
            return
        }

        let focusIsCorrect = isSystemFocused(window)
        let frameIsCorrect = activeWindowFrameMatchesLayout(window)
        guard focusIsCorrect, frameIsCorrect else {
            debugLog("reapplying active layout focusOK=\(focusIsCorrect) frameOK=\(frameIsCorrect)")
            reapplyCurrentLayout(focusActiveWindow: true, verifyFocus: false)
            return
        }

        settleExpectedFocusedWindow(if: window)
    }

    private func activeWindowFrameMatchesLayout(_ window: ManagedWindow) -> Bool {
        guard let expectedItem = currentLayoutItem(for: window), expectedItem.visible else {
            return true
        }
        guard let actualFrame = axFrame(window.element) else {
            return true
        }

        return framesApproximatelyEqual(actualFrame, expectedItem.frame, tolerance: 2)
    }

    private func scheduleActiveLayoutVerification(
        focusActiveWindow: Bool,
        layoutLockDelay: TimeInterval = 0.08
    ) {
        layoutVerificationGeneration &+= 1
        guard !focusActiveWindow, layoutLockDelay > 0 else {
            return
        }
        guard let window = activeWindow() else {
            return
        }

        let generation = layoutVerificationGeneration
        let windowID = ObjectIdentifier(window)
        for delay in [0.06, 0.16, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.verifyActiveLayout(
                    windowID: windowID,
                    generation: generation,
                    focusActiveWindow: focusActiveWindow
                )
            }
        }
    }

    private func verifyActiveLayout(
        windowID: ObjectIdentifier,
        generation: UInt64,
        focusActiveWindow: Bool
    ) {
        guard generation == layoutVerificationGeneration,
              animationTimer == nil,
              let window = activeWindow(),
              ObjectIdentifier(window) == windowID
        else {
            return
        }

        guard activeWindowFrameMatchesLayout(window) else {
            debugLog("forcing active layout correction for \(window.appName)")
            forceActiveWindowLayout(window, focusActiveWindow: focusActiveWindow)
            return
        }
    }

    private func forceActiveWindowLayout(_ window: ManagedWindow, focusActiveWindow: Bool) {
        guard let expectedItem = currentLayoutItem(for: window), expectedItem.visible else {
            return
        }

        applyFrame(expectedItem.frame, to: window, force: true)
        setWindowAlpha(1, for: window.windowID)
        if focusActiveWindow {
            requestFocus(window, verify: false, delay: 0)
        }
    }

    private func systemFrameMatchesCurrentLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let expectedItem = currentLayoutItem(for: window),
              let actualFrame = axFrame(element),
              framesApproximatelyEqual(actualFrame, expectedItem.frame, tolerance: 2)
        else {
            return false
        }

        appliedFrames[ObjectIdentifier(window)] = actualFrame
        return true
    }

    private func currentLayoutItem(for window: ManagedWindow) -> LayoutItem? {
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: captureLayoutState(), parkHidden: true)
        return layout.first { $0.window === window }
    }

    private func framesApproximatelyEqual(_ left: CGRect, _ right: CGRect, tolerance: CGFloat) -> Bool {
        abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }

    private func reapplyCurrentLayout(focusActiveWindow: Bool, verifyFocus: Bool) {
        clearAppliedLayoutCache()
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: captureLayoutState(), parkHidden: true)
        applyLayout(
            layout,
            focusActiveWindow: focusActiveWindow,
            verifyFocus: verifyFocus,
            forceFocusedFrame: focusActiveWindow
        )
        restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
    }

    private func confirmExpectedFocusedWindowIfNeeded(_ window: ManagedWindow) -> Bool {
        guard isSystemFocused(window) else {
            return false
        }

        if activeWindowFrameMatchesLayout(window) {
            settleExpectedFocusedWindow(if: window)
            return true
        }

        return false
    }

    private func reconcileExpectedFocusChange(pid: pid_t) -> Bool {
        guard let expectedID = expectedFocusedWindowID(),
              let expectedWindow = activeWindow(),
              ObjectIdentifier(expectedWindow) == expectedID
        else {
            return false
        }

        guard !isApplyingLayout, animationTimer == nil else {
            debugLog("ignoring focus drift during column animation")
            return true
        }

        if pid == expectedWindow.pid, confirmExpectedFocusedWindowIfNeeded(expectedWindow) {
            return true
        }

        debugLog("ignoring focus drift while targeting \(expectedWindow.appName)")
        focus(expectedWindow, verify: false)
        return true
    }

    private func isSystemFocused(_ window: ManagedWindow) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              let app = NSRunningApplication(processIdentifier: window.pid),
              let focused = focusedWindow(for: app)
        else {
            return false
        }

        return sameWindow(window.element, focused)
    }

    private func activeWindow() -> ManagedWindow? {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return nil
        }
        workspace.clampFocus()
        return workspace.columns[workspace.activeColumn]
    }

    private func allWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns) + floatingWindows
    }

    private func tiledWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns)
    }

    private var persistLayoutEnabled: Bool {
        config.persistLayout ?? MiriConfig.fallback.persistLayout ?? true
    }

    private var persistentLayoutStateURL: URL {
        if let statePath = config.statePath, !statePath.isEmpty {
            return URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
        }

        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        return stateHome
            .appendingPathComponent("miri", isDirectory: true)
            .appendingPathComponent("layout.json")
    }

    private func readPersistentLayoutSnapshot() -> PersistentLayoutSnapshot? {
        guard persistLayoutEnabled,
              let data = try? Data(contentsOf: persistentLayoutStateURL),
              let snapshot = try? JSONDecoder().decode(PersistentLayoutSnapshot.self, from: data),
              (1...2).contains(snapshot.version)
        else {
            return nil
        }
        return snapshot
    }

    private func writeLayoutSnapshots(viewport: CGRect, timing: LayoutSnapshotTiming) {
        switch timing {
        case .immediate:
            cancelTimer(&snapshotWriteTimer)
            pendingSnapshotViewport = nil
            writeLayoutSnapshotsNow(viewport: viewport)
        case .deferred:
            pendingSnapshotViewport = viewport
            if let snapshotWriteTimer {
                snapshotWriteTimer.schedule(
                    deadline: .now() + .milliseconds(180),
                    leeway: .milliseconds(40)
                )
                return
            }

            snapshotWriteTimer = makeMainTimer(
                deadline: .now() + .milliseconds(180),
                leeway: .milliseconds(40)
            ) { [weak self] in
                self?.flushDeferredLayoutSnapshots()
            }
        }
    }

    private func flushDeferredLayoutSnapshots() {
        cancelTimer(&snapshotWriteTimer)

        let viewport = pendingSnapshotViewport ?? currentViewport()
        pendingSnapshotViewport = nil
        writeLayoutSnapshotsNow(viewport: viewport)
    }

    private func writeLayoutSnapshotsNow(viewport: CGRect) {
        writeRestoreSnapshot(viewport: viewport)
        writePersistentLayoutSnapshot()
    }

    private func writePersistentLayoutSnapshot() {
        guard persistLayoutEnabled else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            lastPersistentLayoutSnapshotData = nil
            return
        }

        let states = workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentWindowState(
                    identity: persistentIdentity(for: window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: window.manualWidthRatio
                )
            }
        }
        guard !states.isEmpty else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            lastPersistentLayoutSnapshotData = nil
            return
        }

        let snapshot = PersistentLayoutSnapshot(
            version: 2,
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            focusedWindow: activeWindow().map(persistentIdentity(for:)),
            windows: states
        )

        do {
            let url = persistentLayoutStateURL
            let data = try JSONEncoder().encode(snapshot)
            if lastPersistentLayoutSnapshotData == data,
               FileManager.default.fileExists(atPath: url.path)
            {
                return
            }

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
            lastPersistentLayoutSnapshotData = data
        } catch {
            debugLog("failed to write persistent layout: \(error)")
        }
    }

    @discardableResult
    private func applyPersistentLayoutSnapshotIfNeeded() -> Bool {
        guard needsPersistentLayoutRestore else {
            return false
        }

        guard let snapshot = persistentLayoutSnapshot else {
            needsPersistentLayoutRestore = false
            return false
        }

        var usedSnapshotIndices = Set<Int>()
        var placements: [(state: PersistentWindowState, window: ManagedWindow)] = []
        for window in tiledWindows() {
            guard let state = persistentWindowState(for: window, in: snapshot, used: &usedSnapshotIndices) else {
                continue
            }
            window.manualWidthRatio = state.manualWidthRatio
            placements.append((state, window))
        }

        guard !placements.isEmpty else {
            return false
        }
        needsPersistentLayoutRestore = false

        let placedIDs = Set(placements.map { ObjectIdentifier($0.window) })
        let workspaceCount = max(
            workspaces.count,
            (placements.map(\.state.workspace).max() ?? 0) + 1,
            snapshot.activeWorkspace + 1,
            1
        )
        let nextWorkspaces = (0..<workspaceCount).map { _ in Workspace() }

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let targetWorkspace = nextWorkspaces[min(workspaceIndex, nextWorkspaces.count - 1)]
            for window in workspace.columns where !placedIDs.contains(ObjectIdentifier(window)) {
                targetWorkspace.columns.append(window)
            }
        }

        let sortedPlacements = placements.sorted {
            if $0.state.workspace != $1.state.workspace {
                return $0.state.workspace < $1.state.workspace
            }
            return $0.state.column < $1.state.column
        }
        for placement in sortedPlacements {
            let workspaceIndex = min(max(placement.state.workspace, 0), nextWorkspaces.count - 1)
            let workspace = nextWorkspaces[workspaceIndex]
            workspace.columns.insert(placement.window, at: min(max(placement.state.column, 0), workspace.columns.count))
        }

        workspaces = nextWorkspaces
        activeWorkspace = min(max(snapshot.activeWorkspace, 0), workspaces.count - 1)
        for (index, workspace) in workspaces.enumerated() {
            if snapshot.activeColumns.indices.contains(index) {
                workspace.activeColumn = snapshot.activeColumns[index]
            }
            if let scrollOffsets = snapshot.scrollOffsets, scrollOffsets.indices.contains(index) {
                workspace.scrollOffset = scrollOffsets[index]
            } else {
                workspace.scrollOffset = nil
            }
            workspace.clampFocus()
        }
        return true
    }

    private func restorePersistentFocusedWindow() -> Bool {
        guard let focusedWindow = persistentLayoutSnapshot?.focusedWindow,
              let location = tiledWindowLocation(matching: focusedWindow)
        else {
            return false
        }

        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        return true
    }

    private func persistentWindowState(
        for window: ManagedWindow,
        in snapshot: PersistentLayoutSnapshot,
        used: inout Set<Int>
    ) -> PersistentWindowState? {
        let identity = persistentIdentity(for: window)
        for (index, state) in snapshot.windows.enumerated() where !used.contains(index) && state.identity == identity {
            used.insert(index)
            return state
        }
        return nil
    }

    private func persistentIdentity(for window: ManagedWindow) -> PersistentWindowIdentity {
        PersistentWindowIdentity(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    private func restoreManagedWindowsForExit() {
        guard restoreOnExit else {
            return
        }

        cancelTimer(&snapshotWriteTimer)
        pendingSnapshotViewport = nil
        clearAppliedLayoutCache()
        let viewport = currentViewport()
        for window in allWindows() {
            setWindowAlpha(1, for: window.windowID)
            setWindowLevel(normalWindowLevel, for: window.windowID)
            setAXFrame(viewport, for: window.element)
        }
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    private func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            lastRestoreSnapshotData = nil
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        let floatingIDs = Array(Set(floatingWindows.compactMap(\.windowID))).sorted()
        guard !ids.isEmpty || !floatingIDs.isEmpty else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            lastRestoreSnapshotData = nil
            return
        }

        let snapshot = RestoreSnapshot(
            windowIDs: ids,
            floatingWindowIDs: floatingIDs,
            viewport: RectSnapshot(viewport)
        )
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        if lastRestoreSnapshotData == data,
           FileManager.default.fileExists(atPath: restoreStateURL.path)
        {
            return
        }

        do {
            try data.write(to: restoreStateURL, options: [.atomic])
            lastRestoreSnapshotData = data
        } catch {
            debugLog("failed to write restore snapshot: \(error)")
        }
    }

    private func location(of element: AXUIElement) -> (workspace: Int, column: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() where sameWindow(window.element, element) {
                return (workspaceIndex, columnIndex)
            }
        }
        return nil
    }

    private func tiledWindowLocation(
        for element: AXUIElement
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    private func tiledWindowLocation(
        matching identity: PersistentWindowIdentity
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    private func tiledWindow(for element: AXUIElement) -> ManagedWindow? {
        tiledWindowLocation(for: element)?.window
    }

    private func updateManualWidthRatio(for element: AXUIElement) -> Bool {
        guard let location = tiledWindowLocation(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        guard location.workspaceIndex == activeWorkspace else {
            return false
        }

        let ratio = (frame.width / viewport.width).clampedManualWidthRatio
        let previousRatio = location.window.manualWidthRatio
        let oldScrollOffset = location.workspace.scrollOffset
        location.window.manualWidthRatio = ratio

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        location.workspace.scrollOffset = newScrollOffset
        location.workspace.activeColumn = location.columnIndex
        presentationFrames[ObjectIdentifier(location.window)] = frame

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
        {
            return false
        }

        return true
    }

    private func beginOrContinueManualResize(for element: AXUIElement) {
        cancelHoverFocus()
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility(raise: true)
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        manualResizeElement = element
        cancelTimer(&manualResizeEndTimer)
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element) {
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0, snapshotTiming: .deferred)
        }

        scheduleManualResizeEnd(for: element)
    }

    private var manualResizeNotificationsSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < manualResizeSuppressedUntil
    }

    private func suppressManualResizeNotifications(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }
        manualResizeSuppressedUntil = max(manualResizeSuppressedUntil, CFAbsoluteTimeGetCurrent() + duration)
    }

    private func scheduleManualResizeEnd(for element: AXUIElement) {
        manualResizeEndTimer = makeMainTimer(
            deadline: .now() + .milliseconds(140),
            leeway: .milliseconds(20)
        ) { [weak self] in
            guard let self else {
                return
            }

            cancelTimer(&manualResizeEndTimer)

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                _ = updateManualWidthRatio(for: element)
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                manualResizeElement = nil
            }
        }
    }

    private func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeElement.map { sameWindow($0, element) } ?? false
    }

    private func frameWidthDiffersFromLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let frameRatio = (frame.width / viewport.width).clampedManualWidthRatio
        return abs(frameRatio - widthRatio(for: window)) >= 0.005
    }

    @discardableResult
    private func adoptFocusedWindow(
        pid: pid_t?,
        applyLayout: Bool = true,
        respectFocusSuppression: Bool = false
    ) -> Bool {
        if respectFocusSuppression, shouldSuppressFocusedWindowAdoption {
            return false
        }

        guard let pid else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let focused = value else {
            return false
        }

        let focusedElement = focused as! AXUIElement
        if floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        if let loc = location(of: focusedElement) {
            clearTrackpadCamera()
            let workspace = workspaces[loc.workspace]
            let changedFocus = activeWorkspace != loc.workspace || workspace.activeColumn != loc.column
            setActiveWorkspace(loc.workspace)
            workspace.activeColumn = loc.column
            if changedFocus {
                workspace.scrollOffset = nil
            }
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        return false
    }

    private func startObservingApp(pid: pid_t) {
        guard observers[pid] == nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        if transientSystemWindowIsActive(forceRefresh: true) {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard !reconcileExpectedFocusChange(pid: pid) else {
                return
            }
            guard !shouldSuppressFocusedWindowAdoption else {
                return
            }
            rescanWindows(adoptFocused: false)
            adoptFocusedWindow(pid: pid, respectFocusSuppression: true)
        case kAXCreatedNotification, kAXUIElementDestroyedNotification:
            scheduleRescan(after: 0.08, adoptFocused: true)
        case kAXWindowResizedNotification:
            guard let location = tiledWindowLocation(for: element) else {
                restoreFloatingVisibility(raise: true)
                return
            }
            guard location.workspaceIndex == activeWorkspace else {
                return
            }
            guard !manualResizeNotificationsSuppressed else {
                return
            }
            guard !systemFrameMatchesCurrentLayout(for: element) else {
                return
            }
            invalidateAppliedLayoutCache(for: element)

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
            if manualResizeNotificationsSuppressed, tiledWindow(for: element) != nil {
                return
            }
            if let location = tiledWindowLocation(for: element), location.workspaceIndex != activeWorkspace {
                return
            }
            guard !systemFrameMatchesCurrentLayout(for: element) else {
                return
            }
            invalidateAppliedLayoutCache(for: element)

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility(raise: true)
                    return
                }
                if frameWidthDiffersFromLayout(for: element) {
                    beginOrContinueManualResize(for: element)
                    return
                }
                if let frame = axFrame(element) {
                    presentationFrames[ObjectIdentifier(window)] = frame
                }
                projectLayout(focusActiveWindow: false)
            }
        default:
            break
        }
    }

    private func sameWindow(_ left: AXUIElement, _ right: AXUIElement) -> Bool {
        CFEqual(left, right)
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.reenableEventTap()
        return nil
    }

    guard type == .keyDown || type == .mouseMoved else {
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        app.handleMouseMoved(event)
        return Unmanaged.passUnretained(event)
    }

    if app.handleKeyEvent(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()
    app.handleAXNotification(notification as String, element: element)
}
