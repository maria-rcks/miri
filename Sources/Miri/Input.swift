import CoreGraphics

enum KeyCode {
    static let one: Int64 = 18
    static let two: Int64 = 19
    static let three: Int64 = 20
    static let four: Int64 = 21
    static let five: Int64 = 23
    static let six: Int64 = 22
    static let seven: Int64 = 26
    static let eight: Int64 = 28
    static let nine: Int64 = 25
    static let zero: Int64 = 29
    static let a: Int64 = 0
    static let s: Int64 = 1
    static let d: Int64 = 2
    static let h: Int64 = 4
    static let g: Int64 = 5
    static let z: Int64 = 6
    static let x: Int64 = 7
    static let c: Int64 = 8
    static let w: Int64 = 13
    static let r: Int64 = 15
    static let t: Int64 = 17
    static let j: Int64 = 38
    static let k: Int64 = 40
    static let l: Int64 = 37
    static let equal: Int64 = 24
    static let minus: Int64 = 27
    static let tab: Int64 = 48
    static let home: Int64 = 115
    static let pageUp: Int64 = 116
    static let end: Int64 = 119
    static let pageDown: Int64 = 121
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124
    static let downArrow: Int64 = 125
    static let upArrow: Int64 = 126
    static let leftBracket: Int64 = 33
    static let rightBracket: Int64 = 30
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
