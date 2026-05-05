import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func animateLayout(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        duration: TimeInterval,
        animatedWindowIDs: Set<ObjectIdentifier>?,
        resizingWindowID: ObjectIdentifier?
    ) {
        if animationStrategy == .snapshot {
            animateLayoutWithSnapshots(
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

        guard let profile = animationProfile else {
            let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        let duration = animationDuration(duration, using: profile)
        guard duration > 0 else {
            let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        stopAnimation(clearPresentation: false)
        isApplyingLayout = true

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let targetWorkspaceWindowIDs = workspaceWindowIDs(workspaceIndex: targetState.activeWorkspace)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys).intersection(targetWorkspaceWindowIDs)

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
                startsVisible: startByWindow[id]?.visible ?? false,
                endsVisible: targetByWindow[id]?.visible ?? false,
                participates: participates,
                sizeStable: sizeStable
            )
        }

        guard !motions.isEmpty else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        for motion in motions {
            setWindowAlpha(motion.participates && motion.startsVisible ? 1 : 0, for: motion.window.windowID)
            if motion.participates {
                prepareAnimationMotion(motion, profile: profile)
            } else {
                setAXFrame(motion.endFrame, for: motion.window)
            }
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        animationTimer = AnimationTimer(preferredFPS: animationFPS) { [weak self] in
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
                pixelThreshold: animationPixelThreshold(using: profile),
                profile: profile
            )
            restoreFloatingVisibility()

            if isFinalFrame {
                animationTimer?.cancel()
                animationTimer = nil
                applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
        }
    }

    func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }

    func applyAnimationFrame(
        _ motions: [WindowMotion],
        progress: CGFloat,
        viewport: CGRect,
        pixelThreshold: CGFloat,
        profile: AnimationProfile
    ) {
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for motion in motions {
            let id = ObjectIdentifier(motion.window)
            guard motion.participates else {
                continue
            }

            let frame = animationFrame(for: motion, progress: progress, profile: profile)
            let previousFrame = presentationFrames[id] ?? motion.startFrame

            guard frameDelta(from: previousFrame, to: frame) >= pixelThreshold || progress >= 1 else {
                nextPresentationFrames[id] = previousFrame
                continue
            }

            nextPresentationFrames[id] = frame
            applyAnimationVisibility(for: motion, progress: progress)
            if motion.sizeStable || !shouldApplyAnimatedSize(for: motion, profile: profile) {
                setAXPosition(frame.origin, for: motion.window.element)
            } else {
                setAXFrame(frame, for: motion.window, disableEnhancedUserInterface: false)
            }
        }

        presentationFrames = nextPresentationFrames
    }

    func applyAnimationVisibility(for motion: WindowMotion, progress: CGFloat) {
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

    func frameDelta(from oldFrame: CGRect, to newFrame: CGRect) -> CGFloat {
        max(
            abs(oldFrame.minX - newFrame.minX),
            abs(oldFrame.minY - newFrame.minY),
            abs(oldFrame.width - newFrame.width),
            abs(oldFrame.height - newFrame.height)
        )
    }

    func stopAnimation(clearPresentation: Bool) {
        animationTimer?.cancel()
        animationTimer = nil
        snapshotAnimationSession?.cancel()
        snapshotAnimationSession = nil
        restoreSnapshotHiddenWindows()
        snapshotOverlayWindow?.hideAndReset()
        if clearPresentation {
            presentationFrames.removeAll()
        }
    }

    func releaseLayoutLock(after delay: TimeInterval = 0.08) {
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

    func softSettleCurve(_ progress: CGFloat) -> CGFloat {
        switch animationCurve {
        case .linear:
            return progress
        case .snappy:
            return cubicBezier(progress, x1: 0.2, y1: 0.0, x2: 0.0, y2: 1.0)
        case .smooth:
            return cubicBezier(progress, x1: 0.16, y1: 0.0, x2: 0.18, y2: 1.0)
        }
    }

    func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
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

    func bezierCoordinate(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * p1
            + 3 * inverse * t * t * p2
            + t * t * t
    }

    func bezierDerivative(_ t: CGFloat, p1: CGFloat, p2: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * p1
            + 6 * inverse * t * (p2 - p1)
            + 3 * t * t * (1 - p2)
    }

    func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

}
