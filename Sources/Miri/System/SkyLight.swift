import ApplicationServices
import Darwin
import Foundation

final class SkyLight: @unchecked Sendable {
    static let shared = SkyLight()

    private typealias SLSMainConnectionID = @convention(c) () -> Int32
    private typealias SLSSetWindowAlpha = @convention(c) (Int32, UInt32, Float) -> Int32
    private typealias SLSSetWindowLevel = @convention(c) (Int32, UInt32, Int32) -> Int32
    private typealias AXUIElementGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32

    private let connectionID: Int32?
    private let setWindowAlpha: SLSSetWindowAlpha?
    private let setWindowLevel: SLSSetWindowLevel?
    private let axUIElementGetWindow: AXUIElementGetWindow?

    private init() {
        let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let hiServicesHandle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )

        let mainConnection = skyLightHandle
            .flatMap { dlsym($0, "SLSMainConnectionID") }
            .map { unsafeBitCast($0, to: SLSMainConnectionID.self) }
        setWindowAlpha = skyLightHandle
            .flatMap { dlsym($0, "SLSSetWindowAlpha") }
            .map { unsafeBitCast($0, to: SLSSetWindowAlpha.self) }
        setWindowLevel = skyLightHandle
            .flatMap { dlsym($0, "SLSSetWindowLevel") }
            .map { unsafeBitCast($0, to: SLSSetWindowLevel.self) }
        axUIElementGetWindow = hiServicesHandle
            .flatMap { dlsym($0, "_AXUIElementGetWindow") }
            .map { unsafeBitCast($0, to: AXUIElementGetWindow.self) }
        connectionID = mainConnection?()
    }

    var canSetAlpha: Bool {
        connectionID != nil && setWindowAlpha != nil
    }

    var canSetWindowLevel: Bool {
        connectionID != nil && setWindowLevel != nil
    }

    func windowID(for element: AXUIElement) -> UInt32? {
        guard let axUIElementGetWindow else {
            return nil
        }

        var id: UInt32 = 0
        let error = axUIElementGetWindow(element, &id)
        return error == AXError.success.rawValue && id != 0 ? id : nil
    }

    func setAlpha(_ alpha: Float, for windowID: UInt32?) {
        guard let connectionID, let setWindowAlpha, let windowID else {
            return
        }
        _ = setWindowAlpha(connectionID, windowID, alpha)
    }

    @discardableResult
    func setLevel(_ level: Int32, for windowID: UInt32?) -> Bool {
        guard let connectionID, let setWindowLevel, let windowID else {
            return false
        }
        return setWindowLevel(connectionID, windowID, level) == 0
    }
}
