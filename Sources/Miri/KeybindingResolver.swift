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
        case "focus_previous_workspace":
            return .focusPreviousWorkspace
        case "workspace_down":
            return .workspaceDown
        case "workspace_up":
            return .workspaceUp
        case "column_left":
            return .columnLeft
        case "column_right":
            return .columnRight
        case "column_first":
            return .columnFirst
        case "column_last":
            return .columnLast
        case "move_column_left":
            return .moveColumnLeft
        case "move_column_right":
            return .moveColumnRight
        case "move_column_to_first":
            return .moveColumnToFirst
        case "move_column_to_last":
            return .moveColumnToLast
        case "move_column_down":
            return .moveColumnToWorkspaceDown
        case "move_column_up":
            return .moveColumnToWorkspaceUp
        case "cycle_width_preset_backward":
            return .cycleWidthPresetBackward
        case "cycle_width_preset_forward":
            return .cycleWidthPresetForward
        case "nudge_width_narrower":
            return .nudgeWidthNarrower
        case "nudge_width_wider":
            return .nudgeWidthWider
        case "cycle_all_width_presets_backward":
            return .cycleAllWidthPresetsBackward
        case "cycle_all_width_presets_forward":
            return .cycleAllWidthPresetsForward
        case "nudge_all_widths_narrower":
            return .nudgeAllWidthsNarrower
        case "nudge_all_widths_wider":
            return .nudgeAllWidthsWider
        default:
            return nil
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
        let modifierPartsList = normalizedModifierPartCandidates(from: modifiers)
        return normalizedKeyNames(keyCode: keyCode, keyText: keyText).flatMap { keyName in
            modifierPartsList.map { modifierParts in
                (modifierParts + [keyName]).joined(separator: "+")
            }
        }
    }

    private static func normalizedModifierPartCandidates(from modifiers: CGEventFlags) -> [[String]] {
        var names = Set<String>()
        if modifiers.contains(.maskCommand) {
            names.insert("cmd")
        }
        if modifiers.contains(.maskControl) {
            names.insert("ctrl")
        }
        if modifiers.contains(.maskShift) {
            names.insert("shift")
        }
        if modifiers.contains(.maskAlternate) {
            names.insert("alt")
        }

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
        ["cmd", "ctrl", "shift", "alt", "lalt", "ralt"].filter { modifiers.contains($0) }
    }

    private static func normalizedKeyNames(keyCode: Int64, keyText: String) -> [String] {
        var names: [String] = []
        let add: (String) -> Void = { name in
            let normalized = normalizedKeyName(name)
            if !names.contains(normalized) {
                names.append(normalized)
            }
        }

        if !keyText.isEmpty {
            add(keyText)
        }

        switch keyCode {
        case KeyCode.one: add("1")
        case KeyCode.two: add("2")
        case KeyCode.three: add("3")
        case KeyCode.four: add("4")
        case KeyCode.five: add("5")
        case KeyCode.six: add("6")
        case KeyCode.seven: add("7")
        case KeyCode.eight: add("8")
        case KeyCode.nine: add("9")
        case KeyCode.zero: add("0")
        case KeyCode.h: add("h")
        case KeyCode.j: add("j")
        case KeyCode.k: add("k")
        case KeyCode.l: add("l")
        case KeyCode.minus:
            add("-")
            add("minus")
        case KeyCode.equal:
            add("=")
            add("equal")
        case KeyCode.home: add("home")
        case KeyCode.end: add("end")
        case KeyCode.leftBracket:
            add("[")
            add("{")
        case KeyCode.rightBracket:
            add("]")
            add("}")
        default:
            break
        }

        return names
    }

    private static func normalizedKeyName(_ key: String) -> String {
        switch key.lowercased() {
        case "leftbracket", "left-bracket", "openbracket", "open-bracket":
            return "["
        case "rightbracket", "right-bracket", "closebracket", "close-bracket":
            return "]"
        case "leftbrace", "left-brace", "openbrace", "open-brace":
            return "{"
        case "rightbrace", "right-brace", "closebrace", "close-brace":
            return "}"
        case "minus":
            return "-"
        case "equal":
            return "="
        default:
            return key
        }
    }
}
