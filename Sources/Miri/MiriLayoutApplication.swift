import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func projectLayout(
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

    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
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

    func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    func trackpadCameraWorkspaceIndex(cameraY: CGFloat, viewport: CGRect) -> Int {
        guard viewport.height > 0, !workspaces.isEmpty else {
            return 0
        }

        return min(max(Int(round(cameraY / viewport.height)), 0), workspaces.count - 1)
    }

    func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) {
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

    func applyLayoutItem(_ item: LayoutItem, forceFrame: Bool = false) {
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

    func restoreFloatingVisibility() {
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
        }
    }

    func focus(_ window: ManagedWindow) {
        setWindowAlpha(1, for: window.windowID)
        suppressFocusedWindowNotificationsUntil = CFAbsoluteTimeGetCurrent() + 0.2
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

}
