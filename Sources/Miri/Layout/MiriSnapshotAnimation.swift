import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

final class SnapshotAnimationSession: @unchecked Sendable {
    let overlay: SnapshotOverlayWindow
    var cancelled = false
    var layersByWindowID: [ObjectIdentifier: CALayer] = [:]
    var generation = 0

    init(overlay: SnapshotOverlayWindow) {
        self.overlay = overlay
    }

    func presentationFrames() -> [ObjectIdentifier: CGRect] {
        Dictionary(uniqueKeysWithValues: layersByWindowID.compactMap { id, layer in
            guard let presentation = layer.presentation() else {
                return nil
            }
            return (id, overlay.axFrame(forLayerFrame: presentation.frame))
        })
    }

    func cancel() {
        guard !cancelled else {
            return
        }
        cancelled = true
        overlay.hideAndReset()
    }
}

final class SnapshotOverlayWindow: @unchecked Sendable {
    let window: NSWindow
    let rootLayer: CALayer
    let axViewport: CGRect

    init?(axViewport: CGRect) {
        guard axViewport.width > 1, axViewport.height > 1 else {
            return nil
        }
        self.axViewport = axViewport

        let frame = SnapshotOverlayWindow.appKitFrame(fromAXFrame: axViewport)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: frame.size)
        rootLayer.masksToBounds = false
        content.layer = rootLayer

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.level = .screenSaver
        window.contentView = content

        self.window = window
        self.rootLayer = rootLayer
    }

    func addSnapshotLayer(image: CGImage, at startFrame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window.backingScaleFactor
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.masksToBounds = true
        layer.frame = layerFrame(forAXFrame: startFrame)
        rootLayer.addSublayer(layer)
        debugSnapshotScaleIfNeeded(image: image, startFrame: startFrame, startLayerFrame: layer.frame)
        return layer
    }

    func animateSnapshotLayer(_ layer: CALayer, to endFrame: CGRect, duration: TimeInterval, timing: CAMediaTimingFunction) {
        let finalFrame = layerFrame(forAXFrame: endFrame)
        let currentFrame = layer.presentation()?.frame ?? layer.frame

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.frame = currentFrame
        CATransaction.commit()

        let startPosition = layer.position
        let startBounds = layer.bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = finalFrame
        CATransaction.commit()

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: startPosition)
        position.toValue = NSValue(point: CGPoint(x: finalFrame.midX, y: finalFrame.midY))
        position.duration = duration
        position.timingFunction = timing
        position.isRemovedOnCompletion = true

        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: startBounds)
        bounds.toValue = NSValue(rect: CGRect(origin: .zero, size: finalFrame.size))
        bounds.duration = duration
        bounds.timingFunction = timing
        bounds.isRemovedOnCompletion = true

        layer.add(position, forKey: "snapshot.position")
        layer.add(bounds, forKey: "snapshot.bounds")
    }

    func show() {
        window.level = .screenSaver
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func hideAndReset() {
        rootLayer.removeAllAnimations()
        rootLayer.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        window.orderOut(nil)
        window.level = .floating
    }

    private func debugSnapshotScaleIfNeeded(image: CGImage, startFrame: CGRect, startLayerFrame: CGRect) {
#if DEBUG
        let imagePointSize = CGSize(
            width: CGFloat(image.width) / max(window.backingScaleFactor, 1),
            height: CGFloat(image.height) / max(window.backingScaleFactor, 1)
        )
        if abs(imagePointSize.width - startFrame.width) > 2 || abs(imagePointSize.height - startFrame.height) > 2 {
            NSLog(
                "miri snapshot scale image=%dx%d imagePoints=(%.1f,%.1f) ax=(%.1f,%.1f) layer=(%.1f,%.1f) scale=%.1f",
                image.width,
                image.height,
                imagePointSize.width,
                imagePointSize.height,
                startFrame.width,
                startFrame.height,
                startLayerFrame.width,
                startLayerFrame.height,
                window.backingScaleFactor
            )
        }
#endif
    }

    func axFrame(forLayerFrame frame: CGRect) -> CGRect {
        CGRect(
            x: axViewport.minX + frame.minX,
            y: axViewport.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func layerFrame(forAXFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - axViewport.minX,
            y: axViewport.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func appKitFrame(fromAXFrame frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let screen else {
            return frame
        }
        return CGRect(
            x: frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

extension Miri {
    func hideSnapshotWindows(_ windows: [ManagedWindow], parkIn viewport: CGRect? = nil) {
        snapshotHiddenWindows = windows
        for window in windows {
            let id = ObjectIdentifier(window)
            setWindowAlpha(0, for: window.windowID)
            appliedVisibility[id] = false
            if let viewport {
                let frame = axFrame(window.element) ?? CGRect(x: viewport.maxX + 8192, y: viewport.minY, width: 320, height: 240)
                let parked = CGRect(
                    x: viewport.maxX + 8192,
                    y: viewport.minY,
                    width: max(frame.width, 320),
                    height: max(frame.height, 240)
                )
                setAXFrame(parked, for: window)
                setWindowAlpha(0, for: window.windowID)
            }
        }
    }

    func restoreSnapshotHiddenWindows() {
        guard !snapshotHiddenWindows.isEmpty else {
            return
        }
        for window in snapshotHiddenWindows {
            guard location(of: window.element)?.workspace == activeWorkspace else {
                continue
            }
            let id = ObjectIdentifier(window)
            setWindowAlpha(1, for: window.windowID)
            appliedVisibility[id] = true
        }
        snapshotHiddenWindows.removeAll()
    }

    func prepareInterruptedSnapshotAnimationForNextCapture() {
        guard let session = snapshotAnimationSession else {
            restoreSnapshotHiddenWindows()
            snapshotOverlayWindow?.hideAndReset()
            return
        }

        let hidden = snapshotHiddenWindows
        let frames = session.presentationFrames()
        session.cancel()
        snapshotAnimationSession = nil
        snapshotHiddenWindows.removeAll()
        for window in tiledWindows() {
            let id = ObjectIdentifier(window)
            guard let frame = frames[id] else {
                continue
            }
            setAXFrame(frame, for: window)
            setWindowAlpha(1, for: window.windowID)
            appliedFrames[id] = frame
            appliedVisibility[id] = true
            presentationFrames[id] = frame
        }
        for window in hidden where frames[ObjectIdentifier(window)] == nil {
            guard location(of: window.element)?.workspace == activeWorkspace else {
                continue
            }
            let id = ObjectIdentifier(window)
            setWindowAlpha(1, for: window.windowID)
            appliedVisibility[id] = true
        }
    }

    func animateLayoutWithSnapshots(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        duration: TimeInterval,
        animatedWindowIDs: Set<ObjectIdentifier>?,
        resizingWindowID: ObjectIdentifier?
    ) {
        let duration = max(0, duration * 0.8)
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)

        guard duration > 0 else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        isApplyingLayout = true
        let requestGeneration = layoutRequestGeneration
        if focusActiveWindow, let activeWindow = activeWindow() {
            focus(activeWindow, reveal: false)
        }

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let targetWorkspaceWindowIDs = workspaceWindowIDs(workspaceIndex: targetState.activeWorkspace)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys).intersection(targetWorkspaceWindowIDs)

        let motions = windowIDs.compactMap { id -> WindowMotion? in
            guard let window = startByWindow[id]?.window ?? targetByWindow[id]?.window else {
                return nil
            }
            let startFrame = snapshotAnimationSession?.presentationFrames()[id]
                ?? presentationFrames[id]
                ?? startByWindow[id]?.frame
                ?? targetByWindow[id]?.frame
            let endFrame = targetByWindow[id]?.frame ?? startFrame
            guard let startFrame, let endFrame else {
                return nil
            }
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                startsVisible: startByWindow[id]?.visible ?? false,
                endsVisible: targetByWindow[id]?.visible ?? false,
                participates: true,
                sizeStable: true
            )
        }

        guard motions.contains(where: { $0.endsVisible && frameDelta(from: $0.startFrame, to: $0.endFrame) >= 1 }) else {
            applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
            restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
            presentationFrames.removeAll()
            releaseLayoutLock()
            return
        }

        let timing = CAMediaTimingFunction(controlPoints: 0.16, 0.0, 0.18, 1.0)

        if let session = snapshotAnimationSession, !session.cancelled {
            session.generation += 1
            let generation = session.generation
            let frames = session.presentationFrames()
            presentationFrames = frames
            for motion in motions {
                guard let layer = session.layersByWindowID[ObjectIdentifier(motion.window)] else {
                    continue
                }
                session.overlay.animateSnapshotLayer(layer, to: motion.endFrame, duration: duration, timing: timing)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.06) { [weak self, session] in
                guard let self, snapshotAnimationSession === session, session.generation == generation, !session.cancelled else {
                    return
                }
                guard layoutRequestGeneration == requestGeneration else {
                    return
                }
                snapshotHiddenWindows.removeAll()
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                session.cancel()
                snapshotAnimationSession = nil
                releaseLayoutLock()
            }
            return
        }

        let snapshotSourceMotions = motions
        for motion in snapshotSourceMotions {
            if !motion.startsVisible {
                setAXFrame(motion.startFrame, for: motion.window)
            }
            setWindowAlpha(1, for: motion.window.windowID)
        }
        CATransaction.flush()

        DispatchQueue.main.async { [weak self] in
            guard let self, snapshotAnimationSession == nil, isApplyingLayout else {
                return
            }

            let snapshotMotions = snapshotSourceMotions.compactMap { motion -> (WindowMotion, CGImage)? in
                guard let windowID = motion.window.windowID,
                      let image = CGWindowListCreateImage(
                        .null,
                        .optionIncludingWindow,
                        CGWindowID(windowID),
                        [.bestResolution, .boundsIgnoreFraming]
                      )
                else {
                    return nil
                }
                return (motion, image)
            }

            guard !snapshotMotions.isEmpty else {
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
                return
            }

            let overlayFrame = snapshotMotions.reduce(viewport) { frame, item in
                frame.union(item.0.startFrame).union(item.0.endFrame)
            }.insetBy(dx: -2, dy: -2)

            let overlay: SnapshotOverlayWindow
            if let newOverlay = SnapshotOverlayWindow(axViewport: overlayFrame) {
                snapshotOverlayWindow?.hideAndReset()
                snapshotOverlayWindow = newOverlay
                overlay = newOverlay
            } else {
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
                return
            }

            let session = SnapshotAnimationSession(overlay: overlay)
            snapshotAnimationSession = session
            session.generation = 1
            let generation = session.generation

            let snapshotLayers = snapshotMotions.map { motion, image in
                (motion: motion, layer: overlay.addSnapshotLayer(image: image, at: motion.startFrame))
            }
            session.layersByWindowID = Dictionary(uniqueKeysWithValues: snapshotLayers.map { item in
                (ObjectIdentifier(item.motion.window), item.layer)
            })
            overlay.show()

            DispatchQueue.main.async { [weak self, session] in
                guard let self, snapshotAnimationSession === session, !session.cancelled else {
                    return
                }
                hideSnapshotWindows(snapshotMotions.map { $0.0.window }, parkIn: nil)
                for item in snapshotLayers {
                    overlay.animateSnapshotLayer(item.layer, to: item.motion.endFrame, duration: duration, timing: timing)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.06) { [weak self, session] in
                guard let self, snapshotAnimationSession === session, session.generation == generation, !session.cancelled else {
                    return
                }
                guard layoutRequestGeneration == requestGeneration else {
                    return
                }
                snapshotHiddenWindows.removeAll()
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                session.cancel()
                snapshotAnimationSession = nil
                releaseLayoutLock()
            }
        }
    }
}
