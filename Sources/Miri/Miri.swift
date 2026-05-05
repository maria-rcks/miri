import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class Miri: NSObject, @unchecked Sendable {
    private var loadedConfig = MiriConfig.loadWithMetadata()
    var config: MiriConfig {
        loadedConfig.config
    }
    var workspaces: [Workspace] = [Workspace()]
    var floatingWindows: [ManagedWindow] = []
    var activeWorkspace: Int = 0
    weak var previousWorkspace: Workspace?
    private var observers: [pid_t: AXObserver] = [:]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var commandByKeybinding: [String: Command] = [:]
    var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:]
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:]
    var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    var appliedVisibility: [ObjectIdentifier: Bool] = [:]
    var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    var snapshotWriteTimer: DispatchSourceTimer?
    @MainActor private var settingsWindowController: SettingsWindowController?
    private var excludedKeybindingSet = Set<String>()
    private var rescanTimer: Timer?
    var debugLoggedWindowSignatures = Set<String>()
    var isApplyingLayout = false
    var animationTimer: DispatchSourceTimer?
    var hoverFocusTimer: DispatchSourceTimer?
    var hoverFocusTarget: ObjectIdentifier?
    var hoverFocusRequiresRearm = false
    var hoverFocusSuppressedUntil: CFAbsoluteTime = 0
    var transientWindowActive = false
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var trackpadNavigation: ThreeFingerTrackpadNavigation?
    var trackpadCameraY: CGFloat?
    var trackpadCameraVelocity = CGPoint.zero
    var trackpadPendingCameraDelta = CGSize.zero
    var trackpadLatestCameraVelocity = CGPoint.zero
    var trackpadRenderTimer: DispatchSourceTimer?
    var trackpadMomentumTimer: DispatchSourceTimer?
    var trackpadMomentumLastFrameAt: CFAbsoluteTime = 0
    var manualResizeEndTimer: DispatchSourceTimer?
    var manualResizeElement: AXUIElement?
    var manualResizeSuppressedUntil: CFAbsoluteTime = 0
    var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    var needsPersistentLayoutRestore = true
    private var signalSources: [DispatchSourceSignal] = []
    private let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miri-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    private var cleanupWatcher: Process?

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
    }

    func currentConfigForStatusBar() -> MiriConfig {
        config
    }

    func currentWorkspaceBarStatus() -> MiriWorkspaceBarStatus {
        guard workspaces.indices.contains(activeWorkspace) else {
            return MiriWorkspaceBarStatus(workspace: activeWorkspace + 1, focusedIndex: nil, windows: [], occupiedWorkspaces: [])
        }

        let workspace = workspaces[activeWorkspace]
        return MiriWorkspaceBarStatus(
            workspace: activeWorkspace + 1,
            focusedIndex: workspace.columns.isEmpty ? nil : workspace.activeColumn,
            windows: workspace.columns.map(workspaceBarWindow),
            occupiedWorkspaces: occupiedWorkspaceSummaries()
        )
    }

    private func occupiedWorkspaceSummaries() -> [MiriWorkspaceSummary] {
        workspaces.enumerated().compactMap { index, workspace in
            guard !workspace.columns.isEmpty else { return nil }
            let focusedIndex = min(max(workspace.activeColumn, 0), workspace.columns.count - 1)
            let focusedWindow = workspaceBarWindow(workspace.columns[focusedIndex])
            let appNames = Array(NSOrderedSet(array: workspace.columns.map(\.appName))) as? [String] ?? workspace.columns.map(\.appName)
            return MiriWorkspaceSummary(
                workspace: index + 1,
                isActive: index == activeWorkspace,
                lastFocusedWindow: focusedWindow,
                appNames: appNames
            )
        }
    }

    private func workspaceBarWindow(_ window: ManagedWindow) -> MiriWorkspaceBarWindow {
        MiriWorkspaceBarWindow(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    func currentStatus() -> MiriStatus {
        let nonEmptyWorkspaceCount = max(1, workspaces.filter { !$0.columns.isEmpty }.count)
        guard let window = activeWindow() else {
            return MiriStatus(
                workspace: activeWorkspace + 1,
                workspaceCount: nonEmptyWorkspaceCount,
                focusedWindow: "None",
                widthPercent: nil
            )
        }

        let title = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
        return MiriStatus(
            workspace: activeWorkspace + 1,
            workspaceCount: nonEmptyWorkspaceCount,
            focusedWindow: title,
            widthPercent: Int((widthRatio(for: window) * 100).rounded())
        )
    }

    func openConfigFromMenu() {
        if let url = loadedConfig.sourceURL {
            NSWorkspace.shared.open(url)
            return
        }

        let fallbackURL = URL(fileURLWithPath: NSString(string: "~/.config/miri/config.json").expandingTildeInPath)
        NSWorkspace.shared.open(fallbackURL)
    }

    func reloadFromMenu() {
        loadedConfig.sourceModificationDate = nil
        _ = reloadConfigIfNeeded()
    }

    func rescanFromMenu() {
        rescanWindows(adoptFocused: true)
    }

    @MainActor func showSettingsFromMenu() {
        let apps = availableRuleApps()
        if let settingsWindowController {
            settingsWindowController.refresh(config: config, availableApps: apps)
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(miri: self, config: config, availableApps: apps)
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func saveConfigFromSettings(_ updatedConfig: MiriConfig) {
        let url = loadedConfig.sourceURL ?? URL(fileURLWithPath: NSString(string: "~/.config/miri/config.json").expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updatedConfig)
            try data.write(to: url, options: [.atomic])
            loadedConfig.sourceModificationDate = nil
            _ = reloadConfigIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save Miri config"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func availableRuleApps() -> [RuleAppInfo] {
        let windowApps = (tiledWindows() + floatingWindows).compactMap { window -> RuleAppInfo? in
            guard let bundleID = window.bundleID, !bundleID.isEmpty else {
                return nil
            }
            return RuleAppInfo(bundleID: bundleID, appName: window.appName)
        }

        let fallbackRunningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RuleAppInfo? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else {
                    return nil
                }
                return RuleAppInfo(bundleID: bundleID, appName: app.localizedName ?? bundleID)
            }

        let apps = windowApps.isEmpty ? fallbackRunningApps : windowApps
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    @MainActor func quitFromMenu() {
        snapshotWriteTimer?.cancel()
        writePersistentLayoutSnapshot()
        if restoreOnExit {
            restoreManagedWindowsForExit()
        }
        NSApp.terminate(nil)
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
    func reloadConfigIfNeeded() -> Bool {
        let previousSourceURL = loadedConfig.sourceURL
        let previousModificationDate = loadedConfig.sourceModificationDate

        if let previousSourceURL {
            let currentModificationDate = MiriConfig.modificationDate(for: previousSourceURL)
            guard currentModificationDate != previousModificationDate else {
                return false
            }

            loadedConfig.sourceModificationDate = currentModificationDate
        }

        let previousRescanInterval = rescanInterval
        let previousRestoreOnExit = restoreOnExit
        let previousTrackpadSettings = trackpadNavigationSettings
        let reloaded = MiriConfig.loadWithMetadata(logLoaded: false)

        guard reloaded.sourceURL != nil else {
            if previousSourceURL != nil {
                fputs("miri: config reload skipped; keeping previous config\n", stderr)
            }
            return false
        }

        loadedConfig = reloaded
        configureInput()

        if trackpadNavigationSettings != previousTrackpadSettings {
            restartTrackpadNavigation()
        }
        if rescanInterval != previousRescanInterval {
            scheduleRescanTimer()
        }
        updateCleanupWatcher(previousRestoreOnExit: previousRestoreOnExit)

        let sourcePath = loadedConfig.sourceURL?.path ?? "fallback"
        print("miri: reloaded config \(sourcePath), \(commandByKeybinding.count) keybindings")
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
        return true
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
                self?.snapshotWriteTimer?.cancel()
                self?.writePersistentLayoutSnapshot()
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

    func restartTrackpadNavigation() {
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
        commandByKeybinding = KeybindingResolver.makeCommandByKeybinding(config: config)
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(KeybindingResolver.normalizedKeybinding(_:)))
    }

    fileprivate func handleEventTapDisabled(_ type: CGEventType) {
        guard let eventTap else {
            debugLog("event tap disabled by \(type), but tap is nil")
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("event tap re-enabled after \(type)")
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> Bool {
        guard !transientSystemWindowIsActive() else {
            return false
        }

        let modifiers = event.flags

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyText = KeybindingResolver.keyboardText(from: event)
        guard !KeybindingResolver.isExcludedKeybinding(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            excludedKeybindingSet: excludedKeybindingSet
        ) else {
            return false
        }

        guard let command = KeybindingResolver.commandForKeyEvent(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            commandByKeybinding: commandByKeybinding
        ) else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.perform(command)
        }
        return true
    }

    func restoreManagedWindowsForExit() {
        guard restoreOnExit else {
            return
        }

        let viewport = currentViewport()
        for window in tiledWindows() {
            setWindowAlpha(1, for: window.windowID)
            setAXFrame(viewport, for: window.element)
        }
        restoreFloatingVisibility()
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            return
        }

        let snapshot = RestoreSnapshot(windowIDs: ids, viewport: RectSnapshot(viewport))
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: restoreStateURL, options: [.atomic])
    }

    @discardableResult
    func adoptFocusedWindow(pid: pid_t?, applyLayout: Bool = true) -> Bool {
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
                revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            }
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        return false
    }

    func startObservingApp(pid: pid_t) {
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
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        logAXNotification(name, element: element)
        if transientSystemWindowIsActive(forceRefresh: true) {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification:
            guard CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil else {
                return
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            adoptFocusedWindow(pid: pid)
        case kAXUIElementDestroyedNotification:
            if removeDestroyedWindowImmediately(element) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.rescanWindows(adoptFocused: false)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.rescanWindows(adoptFocused: true)
                }
            }
        case kAXCreatedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
        case kAXWindowResizedNotification:
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            guard tiledWindow(for: element) != nil else {
                restoreFloatingVisibility()
                return
            }
            guard !manualResizeNotificationsSuppressed else {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            if manualResizeNotificationsSuppressed, tiledWindow(for: element) != nil {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility()
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
        app.handleEventTapDisabled(type)
        return Unmanaged.passUnretained(event)
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
