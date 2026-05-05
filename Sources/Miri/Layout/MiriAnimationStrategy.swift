import CoreGraphics
import Foundation

enum AnimationSizingPolicy {
    case interpolateFrame
    case finalSizeAnimatePosition
}

struct AnimationProfile {
    var sizingPolicy: AnimationSizingPolicy
    var durationScale: CGFloat
    var pixelThresholdScale: CGFloat

    static let smoothAX = AnimationProfile(
        sizingPolicy: .interpolateFrame,
        durationScale: 1,
        pixelThresholdScale: 1
    )

    static let snappy = AnimationProfile(
        sizingPolicy: .finalSizeAnimatePosition,
        durationScale: 0.65,
        pixelThresholdScale: 1
    )
}

extension Miri {
    var animationProfile: AnimationProfile? {
        nil
    }

    func animationDuration(_ duration: TimeInterval, using profile: AnimationProfile) -> TimeInterval {
        max(0, duration * TimeInterval(profile.durationScale))
    }

    func animationPixelThreshold(using profile: AnimationProfile) -> CGFloat {
        max(0, animationPixelThreshold * profile.pixelThresholdScale)
    }

    func animationFrame(for motion: WindowMotion, progress: CGFloat, profile: AnimationProfile) -> CGRect {
        switch profile.sizingPolicy {
        case .interpolateFrame:
            return interpolate(from: motion.startFrame, to: motion.endFrame, progress: progress)
        case .finalSizeAnimatePosition:
            let origin = CGPoint(
                x: motion.startFrame.minX + (motion.endFrame.minX - motion.startFrame.minX) * progress,
                y: motion.startFrame.minY + (motion.endFrame.minY - motion.startFrame.minY) * progress
            )
            return CGRect(origin: origin, size: motion.endFrame.size)
        }
    }

    func prepareAnimationMotion(_ motion: WindowMotion, profile: AnimationProfile) {
        guard motion.participates else {
            return
        }

        switch profile.sizingPolicy {
        case .interpolateFrame:
            return
        case .finalSizeAnimatePosition:
            guard !motion.sizeStable else {
                return
            }
            let startWithFinalSize = CGRect(origin: motion.startFrame.origin, size: motion.endFrame.size)
            setAXFrame(startWithFinalSize, for: motion.window)
        }
    }

    func shouldApplyAnimatedSize(for motion: WindowMotion, profile: AnimationProfile) -> Bool {
        switch profile.sizingPolicy {
        case .interpolateFrame:
            return !motion.sizeStable
        case .finalSizeAnimatePosition:
            return false
        }
    }
}
