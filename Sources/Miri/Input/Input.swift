import Carbon.HIToolbox
import CoreGraphics

enum KeyCode {
    // ANSI letter keys. Values are standard macOS virtual key codes from Carbon.HIToolbox.
    static let a = Int64(kVK_ANSI_A)
    static let b = Int64(kVK_ANSI_B)
    static let c = Int64(kVK_ANSI_C)
    static let d = Int64(kVK_ANSI_D)
    static let e = Int64(kVK_ANSI_E)
    static let f = Int64(kVK_ANSI_F)
    static let g = Int64(kVK_ANSI_G)
    static let h = Int64(kVK_ANSI_H)
    static let i = Int64(kVK_ANSI_I)
    static let j = Int64(kVK_ANSI_J)
    static let k = Int64(kVK_ANSI_K)
    static let l = Int64(kVK_ANSI_L)
    static let m = Int64(kVK_ANSI_M)
    static let n = Int64(kVK_ANSI_N)
    static let o = Int64(kVK_ANSI_O)
    static let p = Int64(kVK_ANSI_P)
    static let q = Int64(kVK_ANSI_Q)
    static let r = Int64(kVK_ANSI_R)
    static let s = Int64(kVK_ANSI_S)
    static let t = Int64(kVK_ANSI_T)
    static let u = Int64(kVK_ANSI_U)
    static let v = Int64(kVK_ANSI_V)
    static let w = Int64(kVK_ANSI_W)
    static let x = Int64(kVK_ANSI_X)
    static let y = Int64(kVK_ANSI_Y)
    static let z = Int64(kVK_ANSI_Z)

    // ANSI number row.
    static let one = Int64(kVK_ANSI_1)
    static let two = Int64(kVK_ANSI_2)
    static let three = Int64(kVK_ANSI_3)
    static let four = Int64(kVK_ANSI_4)
    static let five = Int64(kVK_ANSI_5)
    static let six = Int64(kVK_ANSI_6)
    static let seven = Int64(kVK_ANSI_7)
    static let eight = Int64(kVK_ANSI_8)
    static let nine = Int64(kVK_ANSI_9)
    static let zero = Int64(kVK_ANSI_0)

    // ANSI punctuation and symbols.
    static let equal = Int64(kVK_ANSI_Equal)
    static let minus = Int64(kVK_ANSI_Minus)
    static let rightBracket = Int64(kVK_ANSI_RightBracket)
    static let leftBracket = Int64(kVK_ANSI_LeftBracket)
    static let quote = Int64(kVK_ANSI_Quote)
    static let semicolon = Int64(kVK_ANSI_Semicolon)
    static let backslash = Int64(kVK_ANSI_Backslash)
    static let comma = Int64(kVK_ANSI_Comma)
    static let slash = Int64(kVK_ANSI_Slash)
    static let period = Int64(kVK_ANSI_Period)
    static let grave = Int64(kVK_ANSI_Grave)

    // Editing and whitespace keys.
    static let returnKey = Int64(kVK_Return)
    static let tab = Int64(kVK_Tab)
    static let space = Int64(kVK_Space)
    static let delete = Int64(kVK_Delete)
    static let escape = Int64(kVK_Escape)
    static let forwardDelete = Int64(kVK_ForwardDelete)

    // Function keys.
    static let f1 = Int64(kVK_F1)
    static let f2 = Int64(kVK_F2)
    static let f3 = Int64(kVK_F3)
    static let f4 = Int64(kVK_F4)
    static let f5 = Int64(kVK_F5)
    static let f6 = Int64(kVK_F6)
    static let f7 = Int64(kVK_F7)
    static let f8 = Int64(kVK_F8)
    static let f9 = Int64(kVK_F9)
    static let f10 = Int64(kVK_F10)
    static let f11 = Int64(kVK_F11)
    static let f12 = Int64(kVK_F12)

    // Navigation keys.
    static let home = Int64(kVK_Home)
    static let pageUp = Int64(kVK_PageUp)
    static let end = Int64(kVK_End)
    static let pageDown = Int64(kVK_PageDown)
    static let leftArrow = Int64(kVK_LeftArrow)
    static let rightArrow = Int64(kVK_RightArrow)
    static let downArrow = Int64(kVK_DownArrow)
    static let upArrow = Int64(kVK_UpArrow)
}

enum Command {
    case focusWorkspace(Int)
    case focusPreviousWorkspace
    case workspaceDown
    case workspaceUp
    case columnLeft
    case columnRight
    case columnFirst
    case columnLast
    case moveColumnLeft
    case moveColumnRight
    case moveColumnToFirst
    case moveColumnToLast
    case moveColumnToWorkspace(Int)
    case moveColumnToWorkspaceDown
    case moveColumnToWorkspaceUp
    case cycleWidthPresetBackward
    case cycleWidthPresetForward
    case nudgeWidthNarrower
    case nudgeWidthWider
    case cycleAllWidthPresetsBackward
    case cycleAllWidthPresetsForward
    case nudgeAllWidthsNarrower
    case nudgeAllWidthsWider
}

enum TrackpadNavigationEvent {
    case began
    case changed(delta: CGPoint, velocity: CGPoint)
    case ended(velocity: CGPoint)
}
