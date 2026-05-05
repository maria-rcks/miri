import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum WindowRestoration {
    static func restore(windowIDs: Set<UInt32>, floatingWindowIDs: Set<UInt32>, viewport: CGRect) {
        let restoreWindowIDs = windowIDs.union(floatingWindowIDs)
        guard !restoreWindowIDs.isEmpty else {
            return
        }

        for windowID in restoreWindowIDs {
            SkyLight.shared.setAlpha(1, for: windowID)
            SkyLight.shared.setLevel(Int32(CGWindowLevelForKey(.normalWindow)), for: windowID)
        }

        guard AXIsProcessTrusted() else {
            return
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }

            for element in axWindows {
                guard let windowID = SkyLight.shared.windowID(for: element),
                      restoreWindowIDs.contains(windowID)
                else {
                    continue
                }

                setAXFrame(viewport, for: element)
                SkyLight.shared.setAlpha(1, for: windowID)
            }
        }
    }
}

enum CleanupWatcher {
    static func run(parentPID: pid_t, snapshotPath: String) -> Never {
        while true {
            if !FileManager.default.fileExists(atPath: snapshotPath) {
                exit(0)
            }

            if kill(parentPID, 0) == -1 && errno == ESRCH {
                restore(snapshotPath: snapshotPath)
                try? FileManager.default.removeItem(atPath: snapshotPath)
                exit(0)
            }

            usleep(250_000)
        }
    }

    private static func restore(snapshotPath: String) {
        let url = URL(fileURLWithPath: snapshotPath)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(RestoreSnapshot.self, from: data)
        else {
            return
        }

        WindowRestoration.restore(
            windowIDs: Set(snapshot.windowIDs),
            floatingWindowIDs: Set(snapshot.floatingWindowIDs ?? []),
            viewport: snapshot.viewport.cgRect
        )
    }
}
