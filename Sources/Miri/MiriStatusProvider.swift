import AppKit
import Foundation

extension Miri {
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

    func occupiedWorkspaceSummaries() -> [MiriWorkspaceSummary] {
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

    func workspaceBarWindow(_ window: ManagedWindow) -> MiriWorkspaceBarWindow {
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

    func scheduleRescanTimer() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanInterval, repeats: true) { [weak self] _ in
            self?.handlePeriodicTick()
        }
    }

    func handlePeriodicTick() {
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

}
