import ApplicationServices
import CoreGraphics
import Darwin

struct RuleAppInfo {
    let bundleID: String
    let appName: String
}

struct MiriStatus {
    let workspace: Int
    let workspaceCount: Int
    let focusedWindow: String
    let widthPercent: Int?
}

struct MiriWorkspaceSummary {
    let workspace: Int
    let isActive: Bool
    let lastFocusedWindow: MiriWorkspaceBarWindow?
    let appNames: [String]
}

struct MiriWorkspaceBarStatus {
    let workspace: Int
    let focusedIndex: Int?
    let windows: [MiriWorkspaceBarWindow]
    let occupiedWorkspaces: [MiriWorkspaceSummary]
}

struct MiriWorkspaceBarWindow {
    let bundleID: String?
    let appName: String
    let title: String
}

struct TrackpadNavigationSettings: Equatable {
    var enabled: Bool
    var fingers: Int
    var invertX: Bool
    var invertY: Bool
}

struct FullscreenWindowState {
    let identity: PersistentWindowIdentity
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?
    let bundleID: String?
    let appName: String
    let title: String
    let workspace: Int
    let column: Int
    let leftNeighborID: ObjectIdentifier?
    let rightNeighborID: ObjectIdentifier?
    let leftNeighbor: PersistentWindowIdentity?
    let rightNeighbor: PersistentWindowIdentity?
    let widthRatio: CGFloat
    let wasActive: Bool
}
