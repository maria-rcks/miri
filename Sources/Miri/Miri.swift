import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class Miri: NSObject, @unchecked Sendable {
    private struct TransientSystemWindow {
        var element: AXUIElement
    }

    private var loadedConfig = MiriConfig.loadWithMetadata()
    var config: MiriConfig {
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
    private var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:]
    private var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:]
    private var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    private var appliedVisibility: [ObjectIdentifier: Bool] = [:]
    private var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    private var snapshotWriteTimer: DispatchSourceTimer?
    @MainActor private var settingsWindowController: SettingsWindowController?
    private var excludedKeybindingSet = Set<String>()
    private var rescanTimer: Timer?
    private var debugLoggedWindowSignatures = Set<String>()
    private var isApplyingLayout = false
    private var animationTimer: DispatchSourceTimer?
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
    private lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    private var needsPersistentLayoutRestore = true
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

    private func availableRuleApps() -> [RuleAppInfo] {
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
        hoverFocusRequiresRearm = false
        stopTrackpadMomentum()
        stopAnimation(clearPresentation: false)
        rescanWindows(adoptFocused: false)
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
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
        trackpadCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        if abs(trackpadCameraVelocity.x) < abs(trackpadLatestCameraVelocity.x) {
            trackpadCameraVelocity.x = trackpadLatestCameraVelocity.x
        }
        if abs(trackpadCameraVelocity.y) < abs(trackpadLatestCameraVelocity.y) {
            trackpadCameraVelocity.y = trackpadLatestCameraVelocity.y
        }
        guard abs(trackpadCameraVelocity.x) >= trackpadNavigationMomentumMinVelocity
            || abs(trackpadCameraVelocity.y) >= trackpadNavigationMomentumMinVelocity
        else {
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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.stepTrackpadMomentum()
        }
        trackpadMomentumTimer = timer
        timer.resume()
    }

    private func startTrackpadRenderLoop() {
        guard trackpadRenderTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.flushTrackpadCameraFrame()
        }
        trackpadRenderTimer = timer
        timer.resume()
    }

    private func stopTrackpadRenderLoop() {
        trackpadRenderTimer?.cancel()
        trackpadRenderTimer = nil
    }

    private func flushTrackpadCameraFrame() {
        guard abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 else {
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
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
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

        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)

        if abs(trackpadCameraVelocity.x) < trackpadNavigationMomentumMinVelocity,
           abs(trackpadCameraVelocity.y) < trackpadNavigationMomentumMinVelocity
        {
            stopTrackpadMomentum()
            settleTrackpadCamera(focusActiveWindow: true)
        }
    }

    private func stopTrackpadMomentum() {
        trackpadMomentumTimer?.cancel()
        trackpadMomentumTimer = nil
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
            }
        }

        let clampedY = abs(nextY - (currentY + delta.height)) > 0.5
        return (clampedX, clampedY)
    }

    private func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            trackpadCameraY = nil
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

        if trackpadNavigationSnap != .none {
            trackpadCameraY = nil
        }
        trackpadCameraVelocity = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadPendingCameraDelta = .zero
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
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadCameraY = nil
        trackpadCameraVelocity = .zero
    }

    private func freezeTrackpadCameraForTransition() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()

        if abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 {
            let viewport = currentViewport()
            seedTrackpadCamera(viewport: viewport)
            _ = applyTrackpadCameraDelta(trackpadPendingCameraDelta, viewport: viewport)
            trackpadPendingCameraDelta = .zero
        }

        trackpadLatestCameraVelocity = .zero
        trackpadCameraVelocity = .zero
    }

    private func perform(_ command: Command, animateWorkspace: Bool = false) {
        clearTrackpadCamera()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        let previousFocusedWindowID = activeWindow().map(ObjectIdentifier.init)
        let previousState = captureLayoutState()
        var animated = false
        var frameAnimated = false
        var duration = keyboardAnimationDuration

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            focusWorkspace(oneBasedIndex)
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .workspaceUp:
            guard setActiveWorkspace(activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .columnLeft:
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = max(workspace.activeColumn - 1, 0)
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            animated = true
        case .columnRight:
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = min(workspace.activeColumn + 1, workspace.columns.count - 1)
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
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
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: -1)
        case .moveColumnRight:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: 1)
        case .moveColumnToFirst:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumn(to: 0)
        case .moveColumnToLast:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            animated = moveActiveColumn(to: workspace.columns.count - 1)
        case .moveColumnToWorkspace(let oneBasedIndex):
            moveActiveColumnToWorkspace(oneBasedIndex: oneBasedIndex)
        case .moveColumnToWorkspaceDown:
            moveActiveColumnToWorkspace(relativeOffset: 1)
        case .moveColumnToWorkspaceUp:
            moveActiveColumnToWorkspace(relativeOffset: -1)
        case .cycleWidthPresetBackward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleWidthPresetForward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthNarrower:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthWider:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsBackward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsForward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsNarrower:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsWider:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        }

        let newState = captureLayoutState()
        let newFocusedWindowID = activeWindow().map(ObjectIdentifier.init)
        let animatedWindowIDs = Set([previousFocusedWindowID, newFocusedWindowID].compactMap { $0 })
        projectLayout(
            focusActiveWindow: true,
            animated: animated && (previousState != newState || frameAnimated),
            from: previousState,
            animationDuration: duration,
            animatedWindowIDs: animatedWindowIDs,
            resizingWindowID: newFocusedWindowID
        )
    }

    private func performAnimatedWidthChange(from state: LayoutState, _ change: () -> Bool) -> Bool {
        seedPresentationFrames(from: state)
        guard change() else {
            presentationFrames.removeAll()
            return false
        }
        return true
    }

    private func focusWorkspace(_ oneBasedIndex: Int) {
        guard !workspaces.isEmpty else {
            return
        }

        let requestedIndex = min(max(oneBasedIndex - 1, 0), workspaces.count - 1)
        let targetIndex = workspaceAutoBackAndForth && requestedIndex == activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        setActiveWorkspace(targetIndex)
        activeWorkspaceObject()?.clampFocus()
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
        guard workspace.columns.indices.contains(targetIndex) else {
            return false
        }

        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        schedulePersistentLayoutSnapshotWrite()
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
        return setActiveWindowWidthRatio(widthRatio(for: window) + delta)
    }

    private func nudgeAllWidths(by delta: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(widthRatio(for: window) + delta, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
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
        schedulePersistentLayoutSnapshotWrite()
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
        schedulePersistentLayoutSnapshotWrite()
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
        guard !isApplyingLayout else {
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.adoptFocusedWindow(pid: app.processIdentifier)
        }
        adoptFocusedWindow(pid: app.processIdentifier)
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rescanWindows(adoptFocused: true)
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.projectLayout(focusActiveWindow: false)
        }
    }

    private func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        let discovered = discoverWindows()
        var changed = false

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                let runningApp = NSRunningApplication(processIdentifier: window.pid)
                let temporarilyHidden = isHiddenOrMinimizedWindow(window.element)
                    || runningApp?.isHidden == true
                let likelyFullscreenTransition = !temporarilyHidden
                    && runningApp != nil
                    && behavior(for: window) != .ignore

                if isFullscreenWindow(window.element) || likelyFullscreenTransition {
                    rememberFullscreenWindowState(window)
                    removeWindow(window, preferRightFocus: true)
                    changed = true
                    continue
                }
                if behavior(for: window) == .ignore {
                    setWindowAlpha(1, for: window.windowID)
                }
                if temporarilyHidden {
                    rememberMinimizedWindowState(window)
                }
                removeWindow(window, preferRightFocus: temporarilyHidden)
                changed = true
            }
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            if let existing = allWindows().first(where: { sameWindow($0.element, found.element) }) {
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
                    restoreMinimizedWindowStateIfAvailable(for: found)
                    insertRestoredWindowNearFocused(found, applyLayout: false)
                }
                changed = true
            }
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        ensureTrailingEmptyWorkspace()

        if adoptFocused {
            let adoptedFocusedWindow = adoptFocusedWindow(
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                applyLayout: false
            )
            let restoredPersistentFocus = adoptedFocusedWindow ? false : restorePersistentFocusedWindow()
            projectLayout(
                focusActiveWindow: restoredPersistentFocus,
                layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08
            )
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
    }

    private func discoverWindows() -> [ManagedWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isHidden else {
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

            for element in axWindows {
                if debugLogging, isChromiumBrowser(app) {
                    logRawAXWindowIfNeeded(element, app: app, source: "scan")
                }
                guard !isUnknownSubroleWindow(element),
                      !isHiddenOrMinimizedWindow(element),
                      !isFullscreenWindow(element),
                      isManageableWindow(element) || isKnownWindow(element) || isRememberedFullscreenWindow(element)
                else {
                    continue
                }
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
                if !isKnownWindow(element), isLikelyTransientPopup(window, app: app) {
                    logTransientPopupIfNeeded(window, app: app)
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                if !isKnownWindow(element), isPictureInPictureWindow(window) {
                    logIgnoredPictureInPictureIfNeeded(window, app: app)
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                logDiscoveredWindowIfNeeded(window, app: app)
                guard behavior(for: window) != .ignore else {
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    private func isHiddenOrMinimizedWindow(_ element: AXUIElement) -> Bool {
        axBool(element, kAXMinimizedAttribute) == true
    }

    private func isFullscreenWindow(_ element: AXUIElement) -> Bool {
        axBool(element, "AXFullScreen") == true
    }

    private func isRememberedFullscreenWindow(_ element: AXUIElement) -> Bool {
        fullscreenWindowStates.values.contains { sameWindow($0.element, element) }
    }

    private func isLikelyFullscreenFrame(_ element: AXUIElement) -> Bool {
        guard let frame = axFrame(element) else {
            return false
        }

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let widthMatches = abs(frame.width - screenFrame.width) <= 4
            let heightMatches = abs(frame.height - screenFrame.height) <= 4
            let originMatches = abs(frame.minX - screenFrame.minX) <= 4 && abs(frame.minY - screenFrame.minY) <= 4
            if widthMatches && heightMatches && originMatches {
                return true
            }
        }

        let viewport = currentViewport()
        return frame.width >= viewport.width * 1.2 || frame.height >= viewport.height * 1.2
    }

    private func isManageableWindow(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

        if subrole == "AXUnknown" {
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

    private func isUnknownSubroleWindow(_ element: AXUIElement) -> Bool {
        axString(element, kAXSubroleAttribute) == "AXUnknown"
    }

    private func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

    private func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: focusNewWindow)
    }

    private func insertRestoredWindowNearFocused(_ window: ManagedWindow, applyLayout: Bool = true) {
        let workspace = activeWorkspaceObject() ?? targetWorkspace(for: window)
        workspace.clampFocus()
        let insertionIndex = workspace.columns.isEmpty ? 0 : min(workspace.activeColumn + 1, workspace.columns.count)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: false)
    }

    private func insertWindow(
        _ window: ManagedWindow,
        in workspace: Workspace,
        at insertionIndex: Int,
        applyLayout: Bool,
        focusNewWindow: Bool
    ) {
        let index = min(max(insertionIndex, 0), workspace.columns.count)
        workspace.columns.insert(window, at: index)
        if focusNewWindow {
            workspace.activeColumn = index
        } else if workspace.columns.count > 1, workspace.activeColumn >= index {
            workspace.activeColumn += 1
        }
        workspace.scrollOffset = nil
        if focusNewWindow, let workspaceIndex = workspaces.firstIndex(where: { $0 === workspace }) {
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
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    private func removeWindow(_ window: ManagedWindow, preferRightFocus: Bool = false) {
        let id = ObjectIdentifier(window)
        appliedFrames.removeValue(forKey: id)
        appliedVisibility.removeValue(forKey: id)
        if let index = floatingWindows.firstIndex(where: { $0 === window }) {
            floatingWindows.remove(at: index)
            return
        }

        for workspace in workspaces {
            if let index = workspace.columns.firstIndex(where: { $0 === window }) {
                let wasActive = workspace.activeColumn == index
                workspace.columns.remove(at: index)
                if wasActive && preferRightFocus {
                    workspace.activeColumn = min(index, max(0, workspace.columns.count - 1))
                } else if workspace.activeColumn >= index {
                    workspace.activeColumn = max(0, workspace.activeColumn - 1)
                }
                workspace.scrollOffset = nil
                workspace.clampFocus()
                break
            }
        }
        ensureTrailingEmptyWorkspace()
    }

    private func rememberFullscreenWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        let workspace = location.workspace
        let leftWindow = location.columnIndex > 0 ? workspace.columns[location.columnIndex - 1] : nil
        let rightWindow = location.columnIndex + 1 < workspace.columns.count ? workspace.columns[location.columnIndex + 1] : nil
        let left = leftWindow.map(persistentIdentity(for:))
        let right = rightWindow.map(persistentIdentity(for:))
        let identity = persistentIdentity(for: window)
        fullscreenWindowStates[identity] = FullscreenWindowState(
            identity: identity,
            element: window.element,
            pid: window.pid,
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            workspace: location.workspaceIndex,
            column: location.columnIndex,
            leftNeighborID: leftWindow.map(ObjectIdentifier.init),
            rightNeighborID: rightWindow.map(ObjectIdentifier.init),
            leftNeighbor: left,
            rightNeighbor: right,
            widthRatio: widthRatio(for: window),
            wasActive: activeWorkspace == location.workspaceIndex && workspace.activeColumn == location.columnIndex
        )
    }

    private func restoreExitedFullscreenWindows(discovered: [ManagedWindow]) {
        for found in discovered {
            guard let match = fullscreenWindowStates.first(where: { sameWindow($0.value.element, found.element) || persistentIdentity(for: found) == $0.key }) else {
                continue
            }
            fullscreenWindowStates.removeValue(forKey: match.key)
            found.manualWidthRatio = match.value.widthRatio
            insertRestoredFullscreenWindow(found, state: match.value)
        }
    }

    private func insertRestoredFullscreenWindow(_ window: ManagedWindow, state: FullscreenWindowState) {
        while workspaces.count <= state.workspace {
            workspaces.append(Workspace())
        }
        let workspace = workspaces[min(max(state.workspace, 0), workspaces.count - 1)]
        let index = restoredFullscreenInsertionIndex(in: workspace, state: state)
        insertWindow(window, in: workspace, at: index, applyLayout: false, focusNewWindow: state.wasActive)
    }

    private func restoredFullscreenInsertionIndex(in workspace: Workspace, state: FullscreenWindowState) -> Int {
        let leftIndex = neighborIndex(id: state.leftNeighborID, identity: state.leftNeighbor, in: workspace)
        let rightIndex = neighborIndex(id: state.rightNeighborID, identity: state.rightNeighbor, in: workspace)
        if let leftIndex, let rightIndex, leftIndex < rightIndex {
            return rightIndex
        }
        if let leftIndex {
            return min(leftIndex + 1, workspace.columns.count)
        }
        if let rightIndex, state.leftNeighbor == nil {
            return rightIndex
        }
        if let rightIndex, rightIndex > 0 {
            return rightIndex
        }
        return workspace.columns.count
    }

    private func neighborIndex(id: ObjectIdentifier?, identity: PersistentWindowIdentity?, in workspace: Workspace) -> Int? {
        if let id,
           let index = workspace.columns.firstIndex(where: { ObjectIdentifier($0) == id }) {
            return index
        }
        guard let identity else {
            return nil
        }
        if let exact = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
            return exact
        }
        if let bundleID = identity.bundleID,
           let bundle = workspace.columns.firstIndex(where: { $0.bundleID == bundleID }) {
            return bundle
        }
        return workspace.columns.firstIndex { $0.appName.caseInsensitiveCompare(identity.appName) == .orderedSame }
    }

    private func rememberMinimizedWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        minimizedWindowStates[persistentIdentity(for: window)] = PersistentWindowState(
            identity: persistentIdentity(for: window),
            workspace: location.workspaceIndex,
            column: location.columnIndex,
            manualWidthRatio: widthRatio(for: window)
        )
    }

    private func restoreMinimizedWindowStateIfAvailable(for window: ManagedWindow) {
        let identity = persistentIdentity(for: window)
        guard let state = minimizedWindowStates.removeValue(forKey: identity) else {
            return
        }
        window.manualWidthRatio = state.manualWidthRatio
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
            var index = workspaces.count - 2
            while index >= 0 {
                if index != activeWorkspace && workspaces[index].isEmpty {
                    workspaces.remove(at: index)
                    if activeWorkspace > index {
                        activeWorkspace -= 1
                    }
                }
                if index == 0 {
                    break
                }
                index -= 1
            }
        }

        activeWorkspace = min(max(activeWorkspace, 0), workspaces.count - 1)
        for workspace in workspaces {
            workspace.clampFocus()
        }
    }

    private var debugLogging: Bool {
        config.debugLogging ?? MiriConfig.fallback.debugLogging ?? false
    }

    private func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        animationDuration: TimeInterval? = nil,
        layoutLockDelay: TimeInterval = 0.08,
        animatedWindowIDs: Set<ObjectIdentifier>? = nil,
        resizingWindowID: ObjectIdentifier? = nil
    ) {
        let viewport = currentViewport()

        let targetState = captureLayoutState()
        debugLog("layout workspace=\(targetState.activeWorkspace + 1) tiled=\(tiledWindows().count) floating=\(floatingWindows.count) animated=\(animated)")
        let duration = animationDuration ?? self.animationDuration
        suppressManualResizeNotifications(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        if animated, duration > 0, let previousState {
            animateLayout(
                from: previousState,
                to: targetState,
                viewport: viewport,
                focusActiveWindow: focusActiveWindow,
                duration: duration,
                animatedWindowIDs: animatedWindowIDs,
                resizingWindowID: resizingWindowID
            )
            return
        }

        stopAnimation(clearPresentation: true)
        isApplyingLayout = true
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow)
        restoreFloatingVisibility()
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

    private func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) {
        if focusActiveWindow, let activeWindow = self.activeWindow() {
            let inactiveVisible = layout.filter { $0.visible && $0.window !== activeWindow }
            for item in inactiveVisible {
                applyLayoutItem(item)
            }

            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                applyLayoutItem(activeItem, forceFrame: true)
            }
        } else {
            for item in layout where item.visible {
                applyLayoutItem(item)
            }
        }

        for item in layout where !item.visible {
            applyLayoutItem(item)
        }

        if focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow)
        }
    }

    private func applyLayoutItem(_ item: LayoutItem, forceFrame: Bool = false) {
        let id = ObjectIdentifier(item.window)
        let wasVisible = appliedVisibility[id]
        let previousFrame = appliedFrames[id]
        let shouldApplyFrame = forceFrame
            || item.visible
            || wasVisible != false
            || previousFrame.map { frameDelta(from: $0, to: item.frame) >= animationPixelThreshold } ?? true

        if shouldApplyFrame {
            setAXFrame(item.frame, for: item.window.element)
            appliedFrames[id] = item.frame
        }

        if wasVisible != item.visible {
            setWindowAlpha(item.visible ? 1 : 0, for: item.window.windowID)
            appliedVisibility[id] = item.visible
        }
    }

    private func restoreFloatingVisibility() {
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
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
        if isChromiumTransientElement(element, app: app) {
            return true
        }
        return isOpenAndSavePanelService(app)
    }

    private func isChromiumTransientElement(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        guard isChromiumBrowser(app),
              axString(element, kAXRoleAttribute) == kAXWindowRole,
              isChromiumTransientSubrole(axString(element, kAXSubroleAttribute)),
              isChromiumTransientTitle(axString(element, kAXTitleAttribute) ?? ""),
              let frame = axFrame(element)
        else {
            return false
        }
        return frame.width <= 620 && frame.height <= 620
    }

    private func isLikelyTransientPopup(_ window: ManagedWindow, app: NSRunningApplication) -> Bool {
        // Chromium exposes toolbar bubbles (media controls, profiles, permissions,
        // extension popovers, etc.) as small, often untitled AXWindows. PiP is also
        // app-managed/always-on-top, so don't tile it either.
        guard isChromiumBrowser(app), isChromiumTransientTitle(window.title) else {
            return false
        }
        guard let frame = axFrame(window.element) else {
            return false
        }
        return frame.width <= 620 && frame.height <= 620
    }

    private func isChromiumTransientTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle.isEmpty
            || normalizedTitle == "global media controls"
            || isPictureInPictureTitle(title)
    }

    private func isChromiumTransientSubrole(_ subrole: String?) -> Bool {
        subrole == nil || subrole == kAXStandardWindowSubrole || subrole == "AXUnknown"
    }

    private func isPictureInPictureWindow(_ window: ManagedWindow) -> Bool {
        isPictureInPictureTitle(window.title)
    }

    private func isPictureInPictureTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle == "picture in picture"
            || normalizedTitle == "picture-in-picture"
            || normalizedTitle == "pip"
    }

    private func isChromiumBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        return bundleID == "com.google.Chrome"
            || bundleID == "com.google.Chrome.beta"
            || bundleID == "com.google.Chrome.dev"
            || bundleID == "com.google.Chrome.canary"
            || bundleID == "com.microsoft.edgemac"
            || bundleID == "com.brave.Browser"
            || bundleID == "com.vivaldi.Vivaldi"
            || bundleID == "com.operasoftware.Opera"
            || bundleID == "net.imput.helium"
            || bundleID.hasPrefix("org.chromium.")
    }

    private func setWindowAlpha(_ alpha: Float, for windowID: UInt32?) {
        guard hideMethod == .skyLightAlpha else {
            return
        }
        SkyLight.shared.setAlpha(alpha, for: windowID)
    }

    private func debugLog(_ message: String) {
        guard debugLogging else {
            return
        }
        let line = "miri: \(message)"
        print(line)
        appendDebugLog(line)
    }

    private var debugLogURL: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return configHome.appendingPathComponent("miri/debug.log")
    }

    private func appendDebugLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(timestamp) \(line)\n"
        let url = debugLogURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path), let data = text.data(using: .utf8) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("miri: failed to write debug log: \(error)")
        }
    }

    private func logTransientPopupIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "transient|\(window.bundleID ?? "nil")|\(window.title)|\(frameDescription)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("transient popup ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    private func logIgnoredPictureInPictureIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "pip|\(window.bundleID ?? "nil")|\(window.title)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("picture-in-picture ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    private func logRawAXWindowIfNeeded(_ element: AXUIElement, app: NSRunningApplication, source: String) {
        guard debugLogging else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let title = axString(element, kAXTitleAttribute) ?? ""
        let frameDescription = axFrame(element).map { String(describing: $0) } ?? "nil"
        let windowID = SkyLight.shared.windowID(for: element)
        let signature = "raw|\(source)|\(app.bundleIdentifier ?? "nil")|\(title)|\(frameDescription)|\(windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)

        let role = axString(element, kAXRoleAttribute) ?? "nil"
        let subrole = axString(element, kAXSubroleAttribute) ?? "nil"
        let minimized = axBool(element, kAXMinimizedAttribute).map(String.init) ?? "nil"
        let fullscreen = axBool(element, "AXFullScreen").map(String.init) ?? "nil"
        let manageable = isManageableWindow(element)
        let known = isKnownWindow(element)
        let transientTitle = isChromiumTransientTitle(title)
        let cgInfo = windowID.flatMap { cgWindowDebugInfo(windowID: $0) } ?? "cg=nil"

        debugLog("raw ax window source=\(source) app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) title='\(title)' id=\(windowID.map(String.init) ?? "nil") role=\(role) subrole=\(subrole) frame=\(frameDescription) minimized=\(minimized) fullscreen=\(fullscreen) manageable=\(manageable) known=\(known) chromiumTransientTitle=\(transientTitle) \(cgInfo)")
    }

    private func logAXNotification(_ name: String, element: AXUIElement) {
        guard debugLogging else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid), isChromiumBrowser(app) else { return }
        logRawAXWindowIfNeeded(element, app: app, source: "notification:\(name)")
    }

    private func logDiscoveredWindowIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "\(window.bundleID ?? "nil")|\(window.title)|\(frameDescription)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)

        let role = axString(window.element, kAXRoleAttribute) ?? "nil"
        let subrole = axString(window.element, kAXSubroleAttribute) ?? "nil"
        let modal = axBool(window.element, "AXModal").map(String.init) ?? "nil"
        let minimized = axBool(window.element, kAXMinimizedAttribute).map(String.init) ?? "nil"
        let fullscreen = axBool(window.element, "AXFullScreen").map(String.init) ?? "nil"
        let positionSettable = isAXAttributeSettable(window.element, kAXPositionAttribute)
        let sizeSettable = isAXAttributeSettable(window.element, kAXSizeAttribute)
        let hasClose = axAttributeExists(window.element, kAXCloseButtonAttribute)
        let hasMinimize = axAttributeExists(window.element, kAXMinimizeButtonAttribute)
        let hasZoom = axAttributeExists(window.element, kAXZoomButtonAttribute)
        let cgInfo = window.windowID.flatMap { cgWindowDebugInfo(windowID: $0) } ?? "cg=nil"

        debugLog("window discovered app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") role=\(role) subrole=\(subrole) frame=\(frameDescription) minimized=\(minimized) fullscreen=\(fullscreen) modal=\(modal) posSettable=\(positionSettable) sizeSettable=\(sizeSettable) buttons(close/min/zoom)=\(hasClose)/\(hasMinimize)/\(hasZoom) activationPolicy=\(app.activationPolicy.rawValue) \(cgInfo)")
    }

    private func cgWindowDebugInfo(windowID: UInt32) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first
        else { return nil }
        let layer = info[kCGWindowLayer as String] ?? "nil"
        let alpha = info[kCGWindowAlpha as String] ?? "nil"
        let onscreen = info[kCGWindowIsOnscreen as String] ?? "nil"
        let owner = info[kCGWindowOwnerName as String] ?? "nil"
        let name = info[kCGWindowName as String] ?? "nil"
        let bounds = info[kCGWindowBounds as String] ?? "nil"
        return "cg(layer=\(layer) alpha=\(alpha) onscreen=\(onscreen) owner='\(owner)' name='\(name)' bounds=\(bounds))"
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

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + hoverFocusDelay, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            performHoverFocus(window: window, workspaceIndex: workspaceIndex, columnIndex: columnIndex)
        }
        hoverFocusTimer = timer
        timer.resume()
    }

    private func performHoverFocus(window: ManagedWindow, workspaceIndex: Int, columnIndex: Int) {
        hoverFocusTimer?.cancel()
        hoverFocusTimer = nil
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
        hoverFocusTimer?.cancel()
        hoverFocusTimer = nil
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
        duration: TimeInterval,
        animatedWindowIDs: Set<ObjectIdentifier>?,
        resizingWindowID: ObjectIdentifier?
    ) {
        stopAnimation(clearPresentation: false)
        isApplyingLayout = true

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
            let isAnimationCandidate = animatedWindowIDs?.contains(id) ?? true
            let participates = isAnimationCandidate && startFrame.union(endFrame).intersects(viewport)
            let sizeStable = resizingWindowID != id || (abs(startFrame.width - endFrame.width) < 0.5
                && abs(startFrame.height - endFrame.height) < 0.5)
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                participates: participates,
                sizeStable: sizeStable
            )
        }

        guard !motions.isEmpty else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility()
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        let finalVisibleWindowIDs = Set(finalLayout.filter(\.visible).map { ObjectIdentifier($0.window) })
        for motion in motions {
            let id = ObjectIdentifier(motion.window)
            setWindowAlpha((motion.participates || finalVisibleWindowIDs.contains(id)) ? 1 : 0, for: motion.window.windowID)
            if !motion.participates {
                setAXFrame(motion.endFrame, for: motion.window.element)
            }
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let frameIntervalMS = max(1, Int((1000.0 / Double(animationFPS)).rounded()))
        timer.schedule(deadline: .now(), repeating: .milliseconds(frameIntervalMS), leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            guard let self else {
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
                viewport: viewport,
                pixelThreshold: animationPixelThreshold
            )
            restoreFloatingVisibility()

            if isFinalFrame {
                animationTimer?.cancel()
                animationTimer = nil
                applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
                restoreFloatingVisibility()
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
        }

        animationTimer = timer
        timer.resume()
    }

    private func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }

    private func applyAnimationFrame(
        _ motions: [WindowMotion],
        progress: CGFloat,
        viewport: CGRect,
        pixelThreshold: CGFloat
    ) {
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for motion in motions {
            let id = ObjectIdentifier(motion.window)
            guard motion.participates else {
                continue
            }

            let frame = interpolate(from: motion.startFrame, to: motion.endFrame, progress: progress)
            let previousFrame = presentationFrames[id] ?? motion.startFrame

            guard frameDelta(from: previousFrame, to: frame) >= pixelThreshold || progress >= 1 else {
                nextPresentationFrames[id] = previousFrame
                continue
            }

            nextPresentationFrames[id] = frame
            if motion.sizeStable {
                setAXPosition(frame.origin, for: motion.window.element)
            } else {
                setAXFrame(frame, for: motion.window.element)
            }
        }

        presentationFrames = nextPresentationFrames
    }

    private func frameDelta(from oldFrame: CGRect, to newFrame: CGRect) -> CGFloat {
        max(
            abs(oldFrame.minX - newFrame.minX),
            abs(oldFrame.minY - newFrame.minY),
            abs(oldFrame.width - newFrame.width),
            abs(oldFrame.height - newFrame.height)
        )
    }

    private func stopAnimation(clearPresentation: Bool) {
        animationTimer?.cancel()
        animationTimer = nil
        if clearPresentation {
            presentationFrames.removeAll()
        }
    }

    private func releaseLayoutLock(after delay: TimeInterval = 0.08) {
        guard delay > 0 else {
            isApplyingLayout = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, animationTimer == nil else {
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

    private func revealActiveColumnIfNeeded(in workspace: Workspace, viewport: CGRect) {
        guard !workspace.columns.isEmpty,
              workspace.columns.indices.contains(workspace.activeColumn),
              viewport.width > 0
        else {
            workspace.scrollOffset = nil
            return
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        guard metrics.origins.indices.contains(workspace.activeColumn),
              metrics.widths.indices.contains(workspace.activeColumn)
        else {
            workspace.scrollOffset = nil
            return
        }

        let currentOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        let columnMinX = metrics.origins[workspace.activeColumn]
        let columnMaxX = columnMinX + metrics.widths[workspace.activeColumn]
        var targetOffset = currentOffset

        if columnMinX < currentOffset {
            targetOffset = columnMinX
        } else if columnMaxX > currentOffset + viewport.width {
            targetOffset = columnMaxX - viewport.width
        }

        let maxOffset = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
        targetOffset = min(max(targetOffset, 0), maxOffset)
        workspace.scrollOffset = targetOffset
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

    private func focus(_ window: ManagedWindow) {
        setWindowAlpha(1, for: window.windowID)
        suppressFocusedWindowNotificationsUntil = CFAbsoluteTimeGetCurrent() + 0.2
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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

    private func schedulePersistentLayoutSnapshotWrite() {
        snapshotWriteTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            writePersistentLayoutSnapshot()
            snapshotWriteTimer?.cancel()
            snapshotWriteTimer = nil
        }
        snapshotWriteTimer = timer
        timer.resume()
    }

    private func writePersistentLayoutSnapshot() {
        guard persistLayoutEnabled else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            return
        }

        let states = workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentWindowState(
                    identity: persistentIdentity(for: window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: widthRatio(for: window)
                )
            }
        }
        guard !states.isEmpty else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
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
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
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
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() {
                guard let state = persistentWindowState(
                    for: window,
                    currentWorkspace: workspaceIndex,
                    currentColumn: columnIndex,
                    in: snapshot,
                    used: &usedSnapshotIndices
                ) else {
                    continue
                }
                window.manualWidthRatio = state.manualWidthRatio
                placements.append((state, window))
            }
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
        currentWorkspace: Int,
        currentColumn: Int,
        in snapshot: PersistentLayoutSnapshot,
        used: inout Set<Int>
    ) -> PersistentWindowState? {
        let identity = persistentIdentity(for: window)
        if let exact = bestPersistentWindowState(
            in: snapshot,
            used: used,
            currentWorkspace: currentWorkspace,
            currentColumn: currentColumn,
            matches: { $0.identity == identity }
        ) {
            used.insert(exact.index)
            return exact.state
        }

        if let bundleID = identity.bundleID,
           let bundleMatch = bestPersistentWindowState(
               in: snapshot,
               used: used,
               currentWorkspace: currentWorkspace,
               currentColumn: currentColumn,
               matches: { $0.identity.bundleID == bundleID }
           )
        {
            used.insert(bundleMatch.index)
            return bundleMatch.state
        }

        let normalizedAppName = identity.appName.lowercased()
        if let appMatch = bestPersistentWindowState(
            in: snapshot,
            used: used,
            currentWorkspace: currentWorkspace,
            currentColumn: currentColumn,
            matches: { $0.identity.appName.lowercased() == normalizedAppName }
        ) {
            used.insert(appMatch.index)
            return appMatch.state
        }

        return nil
    }

    private func bestPersistentWindowState(
        in snapshot: PersistentLayoutSnapshot,
        used: Set<Int>,
        currentWorkspace: Int,
        currentColumn: Int,
        matches: (PersistentWindowState) -> Bool
    ) -> (index: Int, state: PersistentWindowState)? {
        var best: (index: Int, state: PersistentWindowState, score: Int)?
        for (index, state) in snapshot.windows.enumerated() where !used.contains(index) && matches(state) {
            let score = abs(state.workspace - currentWorkspace) * 100 + abs(state.column - currentColumn)
            if best == nil || score < best!.score {
                best = (index, state, score)
            }
        }
        return best.map { ($0.index, $0.state) }
    }

    private func persistentIdentity(for window: ManagedWindow) -> PersistentWindowIdentity {
        PersistentWindowIdentity(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    private func restoreManagedWindowsForExit() {
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

    private func writeRestoreSnapshot(viewport: CGRect) {
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

    private func handleFullscreenTransitionIfNeeded(_ element: AXUIElement) -> Bool {
        if (isFullscreenWindow(element) || isLikelyFullscreenFrame(element)), let location = tiledWindowLocation(for: element) {
            rememberFullscreenWindowState(location.window)
            removeWindow(location.window, preferRightFocus: true)
            projectLayout(focusActiveWindow: location.workspace.columns.isEmpty ? false : true, layoutLockDelay: 0.02)
            schedulePersistentLayoutSnapshotWrite()
            return true
        }

        if !isFullscreenWindow(element), !isLikelyFullscreenFrame(element), isRememberedFullscreenWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
            return true
        }

        return false
    }

    private func removeDestroyedWindowImmediately(_ element: AXUIElement) -> Bool {
        if let location = tiledWindowLocation(for: element) {
            let wasActiveWorkspace = activeWorkspace == location.workspaceIndex
            let wasActiveWindow = wasActiveWorkspace && location.workspace.activeColumn == location.columnIndex
            removeWindow(location.window, preferRightFocus: true)
            if wasActiveWindow {
                projectLayout(focusActiveWindow: true, layoutLockDelay: 0.02)
            } else {
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            }
            return true
        }

        if let window = floatingWindows.first(where: { sameWindow($0.element, element) }) {
            removeWindow(window)
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            return true
        }

        return false
    }

    private func updateManualWidthRatio(for element: AXUIElement) -> Bool {
        guard !isFullscreenWindow(element),
              !isLikelyFullscreenFrame(element),
              let location = tiledWindowLocation(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
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
        setActiveWorkspace(location.workspaceIndex)
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
        guard !isFullscreenWindow(element), !isLikelyFullscreenFrame(element) else {
            _ = handleFullscreenTransitionIfNeeded(element)
            return
        }
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility()
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        manualResizeElement = element
        manualResizeEndTimer?.cancel()
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element) {
            schedulePersistentLayoutSnapshotWrite()
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
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
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            manualResizeEndTimer?.cancel()
            manualResizeEndTimer = nil

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                if updateManualWidthRatio(for: element) {
                    schedulePersistentLayoutSnapshotWrite()
                }
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                manualResizeElement = nil
            }
        }

        manualResizeEndTimer = timer
        timer.resume()
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
    private func adoptFocusedWindow(pid: pid_t?, applyLayout: Bool = true) -> Bool {
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

    private func axAttributeExists(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
    }

    private func isAXAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
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
