import CoreGraphics
import Foundation

extension Miri {
    var animationDuration: TimeInterval {
        TimeInterval(config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240) / 1000
    }

    var keyboardAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.keyboardAnimationMS ?? fallback) / 1000
    }

    var hoverFocusAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.hoverFocusAnimationMS ?? fallback) / 1000
    }

    var trackpadSettleAnimationDuration: TimeInterval {
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

    var moveColumnAnimationDuration: TimeInterval {
        let fallback = config.animationDurationMS ?? MiriConfig.fallback.animationDurationMS ?? 240
        return TimeInterval(config.moveColumnAnimationMS ?? fallback) / 1000
    }

    var widthAnimationDuration: TimeInterval {
        let fallback = config.keyboardAnimationMS
            ?? config.animationDurationMS
            ?? MiriConfig.fallback.widthAnimationMS
            ?? 280
        return TimeInterval(config.widthAnimationMS ?? fallback) / 1000
    }

    var animationCurve: AnimationCurve {
        config.animationCurve ?? MiriConfig.fallback.animationCurve ?? .smooth
    }

    var animationFPS: Int {
        config.animationFPS ?? MiriConfig.fallback.animationFPS ?? 30
    }

    var animationPixelThreshold: CGFloat {
        config.animationPixelThreshold ?? MiriConfig.fallback.animationPixelThreshold ?? 2
    }

    var hoverFocusEnabled: Bool {
        (config.hoverToFocus ?? MiriConfig.fallback.hoverToFocus ?? true) && hoverFocusMode != .off
    }

    var hoverFocusDelay: TimeInterval {
        TimeInterval(config.hoverFocusDelayMS ?? MiriConfig.fallback.hoverFocusDelayMS ?? 120) / 1000
    }

    var hoverFocusMaxScrollRatio: CGFloat {
        config.hoverFocusRequiresVisibleRatio
            ?? config.hoverFocusMaxScrollRatio
            ?? MiriConfig.fallback.hoverFocusRequiresVisibleRatio
            ?? MiriConfig.fallback.hoverFocusMaxScrollRatio
            ?? 0.15
    }

    var hoverFocusEdgeTriggerWidth: CGFloat {
        config.hoverFocusEdgeTriggerWidth ?? MiriConfig.fallback.hoverFocusEdgeTriggerWidth ?? 8
    }

    var hoverFocusAfterTrackpad: TimeInterval {
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

    var hoverFocusMode: HoverFocusMode {
        config.hoverFocusMode ?? MiriConfig.fallback.hoverFocusMode ?? .edgeOrVisible
    }

    var workspaceAutoBackAndForth: Bool {
        config.workspaceAutoBackAndForth ?? MiriConfig.fallback.workspaceAutoBackAndForth ?? true
    }

    var focusAlignment: FocusAlignment {
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

    var newWindowPosition: NewWindowPosition {
        config.newWindowPosition ?? MiriConfig.fallback.newWindowPosition ?? .afterActive
    }

    var innerGap: CGFloat {
        config.innerGap ?? MiriConfig.fallback.innerGap ?? 0
    }

    var outerGap: CGFloat {
        config.outerGap ?? MiriConfig.fallback.outerGap ?? 0
    }

    var parkedSliverWidth: CGFloat {
        config.parkedSliverWidth ?? MiriConfig.fallback.parkedSliverWidth ?? 1
    }

    var trackpadNavigationEnabled: Bool {
        config.trackpadNavigation ?? MiriConfig.fallback.trackpadNavigation ?? true
    }

    var trackpadNavigationFingers: Int {
        config.trackpadNavigationFingers ?? MiriConfig.fallback.trackpadNavigationFingers ?? 3
    }

    var trackpadNavigationSensitivity: CGFloat {
        config.trackpadNavigationSensitivity ?? MiriConfig.fallback.trackpadNavigationSensitivity ?? 1.6
    }

    var trackpadNavigationDeceleration: CGFloat {
        config.trackpadNavigationDeceleration ?? MiriConfig.fallback.trackpadNavigationDeceleration ?? 5.5
    }

    var trackpadNavigationMomentumMinVelocity: CGFloat {
        config.trackpadNavigationMomentumMinVelocity
            ?? MiriConfig.fallback.trackpadNavigationMomentumMinVelocity
            ?? 80
    }

    var trackpadNavigationVelocityGain: CGFloat {
        config.trackpadNavigationVelocityGain ?? MiriConfig.fallback.trackpadNavigationVelocityGain ?? 1.35
    }

    var trackpadNavigationSnap: TrackpadNavigationSnap {
        config.trackpadNavigationSnap ?? MiriConfig.fallback.trackpadNavigationSnap ?? .nearestColumn
    }

    var trackpadNavigationInvertX: Bool {
        config.trackpadNavigationInvertX ?? MiriConfig.fallback.trackpadNavigationInvertX ?? false
    }

    var trackpadNavigationInvertY: Bool {
        config.trackpadNavigationInvertY ?? MiriConfig.fallback.trackpadNavigationInvertY ?? false
    }

    var trackpadNavigationSettings: TrackpadNavigationSettings {
        TrackpadNavigationSettings(
            enabled: trackpadNavigationEnabled,
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY
        )
    }

    var widthPresetRatios: [CGFloat] {
        config.presetWidthRatios ?? MiriConfig.fallback.presetWidthRatios ?? [0.5, 0.67, 0.8, 1.0]
    }

    var rescanInterval: TimeInterval {
        TimeInterval(config.rescanIntervalMS ?? MiriConfig.fallback.rescanIntervalMS ?? 1000) / 1000
    }

    var restoreOnExit: Bool {
        config.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true
    }

    var hideMethod: HideMethod {
        config.hideMethod ?? MiriConfig.fallback.hideMethod ?? .skyLightAlpha
    }
}
