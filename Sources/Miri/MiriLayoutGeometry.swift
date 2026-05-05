import AppKit
import CoreGraphics

extension Miri {
    func viewportContains(_ point: CGPoint, viewport: CGRect) -> Bool {
        point.x >= viewport.minX
            && point.x <= viewport.maxX
            && point.y >= viewport.minY
            && point.y <= viewport.maxY
    }

    func visualFrame(_ frame: CGRect, viewport: CGRect) -> CGRect {
        guard innerGap > 0 else {
            return frame
        }

        let inset = min(innerGap / 2, frame.width / 3, frame.height / 3)
        return frame.insetBy(dx: inset, dy: inset)
    }

    func insetViewport(_ viewport: CGRect, by inset: CGFloat) -> CGRect {
        guard inset > 0 else {
            return viewport
        }

        let safeInset = min(inset, viewport.width / 3, viewport.height / 3)
        return viewport.insetBy(dx: safeInset, dy: safeInset)
    }

    func stripFrames(
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

    func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
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

    func revealActiveColumnIfNeeded(in workspace: Workspace, viewport: CGRect) {
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

    func horizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        if let scrollOffset = workspace.scrollOffset {
            return min(max(scrollOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
        }

        let metrics = stripMetrics(for: workspace, viewport: viewport)
        let activeColumn = min(max(workspace.activeColumn, 0), max(workspace.columns.count - 1, 0))
        return defaultScrollOffset(metrics: metrics, activeColumn: activeColumn, viewport: viewport)
    }

    func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
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

    func closestColumn(to scrollOffset: CGFloat, in workspace: Workspace, viewport: CGRect) -> Int {
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

    func mostVisibleColumn(in workspace: Workspace, viewport: CGRect, scrollOffset: CGFloat) -> Int {
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

    func defaultScrollOffset(
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

    func parkedFrame(for window: ManagedWindow, viewport: CGRect, beforeActive: Bool) -> CGRect {
        let width = viewport.width * widthRatio(for: window)
        var frame = CGRect(x: viewport.minX, y: viewport.minY, width: width, height: viewport.height)
        frame.origin.x = beforeActive
            ? viewport.minX - width + parkedSliverWidth
            : viewport.maxX - parkedSliverWidth
        return frame
    }

    func currentViewport() -> CGRect {
        guard let screen = NSScreen.main else {
            return insetViewport(CGDisplayBounds(CGMainDisplayID()), by: outerGap)
        }

        let visible = screen.visibleFrame
        let screenFrame = screen.frame
        let axY = screenFrame.maxY - visible.maxY
        let viewport = CGRect(x: visible.minX, y: axY, width: visible.width, height: visible.height)
        return insetViewport(viewport, by: outerGap)
    }

}
