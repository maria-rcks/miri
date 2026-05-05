import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: focusNewWindow)
    }

    func insertRestoredWindowNearFocused(_ window: ManagedWindow, applyLayout: Bool = true) {
        let workspace = activeWorkspaceObject() ?? targetWorkspace(for: window)
        workspace.clampFocus()
        let insertionIndex = workspace.columns.isEmpty ? 0 : min(workspace.activeColumn + 1, workspace.columns.count)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: false)
    }

    func insertWindow(
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

    func targetWorkspace(for window: ManagedWindow) -> Workspace {
        if let oneBased = rule(for: window)?.workspace {
            let index = max(0, oneBased - 1)
            ensureWorkspaceExists(index)
            return workspaces[index]
        }

        return activeWorkspaceObject() ?? workspaces[0]
    }

    func ensureWorkspaceExists(_ index: Int) {
        while workspaces.count <= index {
            workspaces.append(Workspace())
        }
    }

    func newWindowInsertionIndex(in workspace: Workspace, for window: ManagedWindow) -> Int {
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

    func insertFloatingWindow(_ window: ManagedWindow, applyLayout: Bool = true) {
        if !floatingWindows.contains(where: { $0 === window }) {
            floatingWindows.append(window)
        }
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    func removeWindow(_ window: ManagedWindow, preferRightFocus: Bool = false) {
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

    func rememberFullscreenWindowState(_ window: ManagedWindow) {
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

    func restoreExitedFullscreenWindows(discovered: [ManagedWindow]) {
        for found in discovered {
            guard let match = fullscreenWindowStates.first(where: { sameWindow($0.value.element, found.element) || persistentIdentity(for: found) == $0.key }) else {
                continue
            }
            fullscreenWindowStates.removeValue(forKey: match.key)
            found.manualWidthRatio = match.value.widthRatio
            insertRestoredFullscreenWindow(found, state: match.value)
        }
    }

    func insertRestoredFullscreenWindow(_ window: ManagedWindow, state: FullscreenWindowState) {
        while workspaces.count <= state.workspace {
            workspaces.append(Workspace())
        }
        let workspace = workspaces[min(max(state.workspace, 0), workspaces.count - 1)]
        let index = restoredFullscreenInsertionIndex(in: workspace, state: state)
        insertWindow(window, in: workspace, at: index, applyLayout: false, focusNewWindow: state.wasActive)
    }

    func restoredFullscreenInsertionIndex(in workspace: Workspace, state: FullscreenWindowState) -> Int {
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

    func neighborIndex(id: ObjectIdentifier?, identity: PersistentWindowIdentity?, in workspace: Workspace) -> Int? {
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

    func rememberMinimizedWindowState(_ window: ManagedWindow) {
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

    func restoreMinimizedWindowStateIfAvailable(for window: ManagedWindow) {
        let identity = persistentIdentity(for: window)
        guard let state = minimizedWindowStates.removeValue(forKey: identity) else {
            return
        }
        window.manualWidthRatio = state.manualWidthRatio
    }

    func ensureTrailingEmptyWorkspace() {
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

}
