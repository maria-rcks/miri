import CoreGraphics
import Foundation

struct KeybindingResolver {
    static func makeCommandByKeybinding(config: MiriConfig) -> [String: Command] {
        var configured = MiriConfig.defaultKeybindings
        for (name, bindings) in config.keybindings ?? [:] {
            configured[name] = bindings
        }

        var commands: [String: Command] = [:]
        for name in configured.keys.sorted() {
            let bindings = configured[name] ?? []
            guard let command = command(named: name) else {
                fputs("miri: ignoring unknown keybinding command '\(name)'\n", stderr)
                continue
            }

            for binding in bindings {
                guard let normalized = normalizedKeybinding(binding) else {
                    fputs("miri: ignoring invalid keybinding '\(binding)' for '\(name)'\n", stderr)
                    continue
                }
                if commands[normalized] != nil {
                    fputs("miri: keybinding '\(binding)' is assigned more than once; using '\(name)'\n", stderr)
                }
                commands[normalized] = command
            }
        }

        return commands
    }

    static func commandForKeyEvent(
        modifiers: CGEventFlags,
        keyCode: Int64,
        keyText: String,
        commandByKeybinding: [String: Command]
    ) -> Command? {
        for candidate in normalizedKeybindingCandidates(modifiers: modifiers, keyCode: keyCode, keyText: keyText) {
            if let command = commandByKeybinding[candidate] {
                return command
            }
        }
        return nil
    }

    static func isExcludedKeybinding(
        modifiers: CGEventFlags,
        keyCode: Int64,
        keyText: String,
        excludedKeybindingSet: Set<String>
    ) -> Bool {
        guard !excludedKeybindingSet.isEmpty else {
            return false
        }

        for candidate in normalizedKeybindingCandidates(modifiers: modifiers, keyCode: keyCode, keyText: keyText) {
            if excludedKeybindingSet.contains(candidate) {
                return true
            }
        }

        return false
    }

    static func keyboardText(from event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    static func normalizedKeybinding(_ binding: String) -> String? {
        let parts = binding
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var modifiers = Set<String>()
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command":
                modifiers.insert("cmd")
            case "ctrl", "control":
                modifiers.insert("ctrl")
            case "shift":
                modifiers.insert("shift")
            case "alt", "option", "alternate":
                modifiers.insert("alt")
            case "lalt", "leftalt", "left_alt", "leftoption", "left_option", "left-option":
                modifiers.insert("lalt")
            case "ralt", "rightalt", "right_alt", "rightoption", "right_option", "right-option":
                modifiers.insert("ralt")
            case "fn", "function", "globe":
                modifiers.insert("fn")
            default:
                key = normalizedKeyName(part)
            }
        }

        guard let key else {
            return nil
        }

        return (orderedModifierParts(from: modifiers) + [key]).joined(separator: "+")
    }

    private static func command(named name: String) -> Command? {
        if let index = commandIndex(name, prefix: "focus_workspace_") {
            return .focusWorkspace(index)
        }
        if let index = commandIndex(name, prefix: "move_column_to_workspace_") {
            return .moveColumnToWorkspace(index)
        }

        switch name {
        case "focus_previous_workspace": return .focusPreviousWorkspace
        case "workspace_down": return .workspaceDown
        case "workspace_up": return .workspaceUp
        case "column_left": return .columnLeft
        case "column_right": return .columnRight
        case "column_first": return .columnFirst
        case "column_last": return .columnLast
        case "move_column_left": return .moveColumnLeft
        case "move_column_right": return .moveColumnRight
        case "move_column_to_first": return .moveColumnToFirst
        case "move_column_to_last": return .moveColumnToLast
        case "move_column_down": return .moveColumnToWorkspaceDown
        case "move_column_up": return .moveColumnToWorkspaceUp
        case "cycle_width_preset_backward": return .cycleWidthPresetBackward
        case "cycle_width_preset_forward": return .cycleWidthPresetForward
        case "nudge_width_narrower": return .nudgeWidthNarrower
        case "nudge_width_wider": return .nudgeWidthWider
        case "cycle_all_width_presets_backward": return .cycleAllWidthPresetsBackward
        case "cycle_all_width_presets_forward": return .cycleAllWidthPresetsForward
        case "nudge_all_widths_narrower": return .nudgeAllWidthsNarrower
        case "nudge_all_widths_wider": return .nudgeAllWidthsWider
        default: return nil
        }
    }

    private static func commandIndex(_ name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix),
              let index = Int(name.dropFirst(prefix.count)),
              (1...9).contains(index)
        else {
            return nil
        }
        return index
    }

    private static func normalizedKeybindingCandidates(modifiers: CGEventFlags, keyCode: Int64, keyText: String) -> [String] {
        var candidates: [String] = []
        let appendCandidates: ([String], [String]) -> Void = { modifierParts, keyNames in
            for keyName in keyNames {
                let candidate = (modifierParts + [keyName]).joined(separator: "+")
                if !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }

        for modifierParts in normalizedModifierPartCandidates(from: modifiers) {
            appendCandidates(
                modifierParts,
                normalizedKeyNames(
                    keyCode: keyCode,
                    keyText: keyText,
                    includeFnNavigationAliases: modifiers.contains(.maskSecondaryFn)
                )
            )
        }

        if modifiers.contains(.maskSecondaryFn) {
            var legacyModifiers = modifiers
            legacyModifiers.remove(.maskSecondaryFn)
            for modifierParts in normalizedModifierPartCandidates(from: legacyModifiers) {
                appendCandidates(
                    modifierParts,
                    normalizedKeyNames(keyCode: keyCode, keyText: keyText, includeFnNavigationAliases: false)
                )
            }
        }

        return candidates
    }

    private static func normalizedModifierPartCandidates(from modifiers: CGEventFlags) -> [[String]] {
        var names = Set<String>()
        if modifiers.contains(.maskCommand) { names.insert("cmd") }
        if modifiers.contains(.maskControl) { names.insert("ctrl") }
        if modifiers.contains(.maskShift) { names.insert("shift") }
        if modifiers.contains(.maskAlternate) { names.insert("alt") }
        if modifiers.contains(.maskSecondaryFn) { names.insert("fn") }

        let generic = orderedModifierParts(from: names)
        var candidates = [generic]

        if modifiers.rawValue & 0x00000020 != 0, names.contains("alt") {
            var leftAltNames = names
            leftAltNames.remove("alt")
            leftAltNames.insert("lalt")
            candidates.append(orderedModifierParts(from: leftAltNames))
        }
        if modifiers.rawValue & 0x00000040 != 0, names.contains("alt") {
            var rightAltNames = names
            rightAltNames.remove("alt")
            rightAltNames.insert("ralt")
            candidates.append(orderedModifierParts(from: rightAltNames))
        }

        return candidates
    }

    private static func orderedModifierParts(from modifiers: Set<String>) -> [String] {
        ["cmd", "ctrl", "shift", "alt", "lalt", "ralt", "fn"].filter { modifiers.contains($0) }
    }

    private static func normalizedKeyNames(keyCode: Int64, keyText: String, includeFnNavigationAliases: Bool) -> [String] {
        var names: [String] = []
        let add: (String) -> Void = { name in
            let normalized = normalizedKeyName(name)
            if !names.contains(normalized) { names.append(normalized) }
        }

        if !keyText.isEmpty { add(keyText) }
        for name in keyNamesByCode[keyCode] ?? [] { add(name) }
        if includeFnNavigationAliases {
            for name in fnNavigationKeyAliasesByCode[keyCode] ?? [] { add(name) }
        }
        return names
    }

    private static func normalizedKeyName(_ key: String) -> String {
        keyNameAliases[key.lowercased()] ?? key
    }

    private static let keyNamesByCode: [Int64: [String]] = [
        KeyCode.a: ["a"], KeyCode.b: ["b"], KeyCode.c: ["c"], KeyCode.d: ["d"],
        KeyCode.e: ["e"], KeyCode.f: ["f"], KeyCode.g: ["g"], KeyCode.h: ["h"],
        KeyCode.i: ["i"], KeyCode.j: ["j"], KeyCode.k: ["k"], KeyCode.l: ["l"],
        KeyCode.m: ["m"], KeyCode.n: ["n"], KeyCode.o: ["o"], KeyCode.p: ["p"],
        KeyCode.q: ["q"], KeyCode.r: ["r"], KeyCode.s: ["s"], KeyCode.t: ["t"],
        KeyCode.u: ["u"], KeyCode.v: ["v"], KeyCode.w: ["w"], KeyCode.x: ["x"],
        KeyCode.y: ["y"], KeyCode.z: ["z"],
        KeyCode.one: ["1"], KeyCode.two: ["2"], KeyCode.three: ["3"], KeyCode.four: ["4"],
        KeyCode.five: ["5"], KeyCode.six: ["6"], KeyCode.seven: ["7"], KeyCode.eight: ["8"],
        KeyCode.nine: ["9"], KeyCode.zero: ["0"],
        KeyCode.minus: ["-", "minus"], KeyCode.equal: ["=", "equal"],
        KeyCode.leftBracket: ["[", "{"], KeyCode.rightBracket: ["]", "}"],
        KeyCode.semicolon: [";"], KeyCode.quote: ["'"], KeyCode.comma: [","],
        KeyCode.period: ["."], KeyCode.slash: ["/"], KeyCode.backslash: ["\\"], KeyCode.grave: ["`"],
        KeyCode.tab: ["tab"], KeyCode.space: ["space"], KeyCode.returnKey: ["return", "enter"],
        KeyCode.escape: ["escape"], KeyCode.delete: ["delete", "backspace"],
        KeyCode.forwardDelete: ["forward-delete"],
        KeyCode.home: ["home"], KeyCode.end: ["end"], KeyCode.pageUp: ["pageup"],
        KeyCode.pageDown: ["pagedown"], KeyCode.leftArrow: ["left"], KeyCode.rightArrow: ["right"],
        KeyCode.upArrow: ["up"], KeyCode.downArrow: ["down"],
        KeyCode.f1: ["f1"], KeyCode.f2: ["f2"], KeyCode.f3: ["f3"], KeyCode.f4: ["f4"],
        KeyCode.f5: ["f5"], KeyCode.f6: ["f6"], KeyCode.f7: ["f7"], KeyCode.f8: ["f8"],
        KeyCode.f9: ["f9"], KeyCode.f10: ["f10"], KeyCode.f11: ["f11"], KeyCode.f12: ["f12"],
    ]

    private static let fnNavigationKeyAliasesByCode: [Int64: [String]] = [
        KeyCode.leftArrow: ["home"], KeyCode.rightArrow: ["end"],
        KeyCode.upArrow: ["pageup"], KeyCode.downArrow: ["pagedown"],
        KeyCode.home: ["left"], KeyCode.end: ["right"],
        KeyCode.pageUp: ["up"], KeyCode.pageDown: ["down"],
    ]

    private static let keyNameAliases: [String: String] = [
        "leftbracket": "[", "left-bracket": "[", "openbracket": "[", "open-bracket": "[",
        "rightbracket": "]", "right-bracket": "]", "closebracket": "]", "close-bracket": "]",
        "leftbrace": "{", "left-brace": "{", "openbrace": "{", "open-brace": "{",
        "rightbrace": "}", "right-brace": "}", "closebrace": "}", "close-brace": "}",
        "minus": "-", "hyphen": "-", "dash": "-", "equal": "=", "equals": "=",
        "semicolon": ";", "quote": "'", "apostrophe": "'", "singlequote": "'", "single-quote": "'",
        "comma": ",", "period": ".", "dot": ".", "fullstop": ".", "full-stop": ".",
        "slash": "/", "forwardslash": "/", "forward-slash": "/",
        "backslash": "\\", "back-slash": "\\", "grave": "`", "backtick": "`", "backquote": "`",
        "esc": "escape", "enter": "return", "backspace": "delete",
        "forwarddelete": "forward-delete", "fwddelete": "forward-delete", "del": "forward-delete",
        "spacebar": "space",
        "leftarrow": "left", "left-arrow": "left", "arrowleft": "left", "arrow-left": "left",
        "rightarrow": "right", "right-arrow": "right", "arrowright": "right", "arrow-right": "right",
        "uparrow": "up", "up-arrow": "up", "arrowup": "up", "arrow-up": "up",
        "downarrow": "down", "down-arrow": "down", "arrowdown": "down", "arrow-down": "down",
        "pgup": "pageup", "page-up": "pageup", "page_up": "pageup",
        "pgdn": "pagedown", "pgdown": "pagedown", "page-down": "pagedown", "page_down": "pagedown",
    ]
}
