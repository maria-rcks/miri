import CoreGraphics
import Foundation

enum WindowBehavior: String, Codable {
    case tile
    case float
    case ignore
}

enum FocusAlignment: String, Codable {
    case left
    case center
    case smart
}

enum NewWindowPosition: String, Codable {
    case beforeActive = "before_active"
    case afterActive = "after_active"
    case end
}

enum HideMethod: String, Codable {
    case skyLightAlpha = "skylight_alpha"
    case parkOnly = "park_only"
}

enum AnimationCurve: String, Codable {
    case smooth
    case snappy
    case linear
}

enum HoverFocusMode: String, Codable {
    case off
    case visibleOnly = "visible_only"
    case edgeOrVisible = "edge_or_visible"
}

enum TrackpadNavigationSnap: String, Codable {
    case nearestColumn = "nearest_column"
    case nearestVisible = "nearest_visible"
    case none
}

struct LoadedMiriConfig {
    var config: MiriConfig
    var sourceURL: URL?
    var sourceModificationDate: Date?
}

struct MiriConfig: Codable {
    var defaultWidthRatio: CGFloat
    var presetWidthRatios: [CGFloat]?
    var animationDurationMS: Int?
    var keyboardAnimationMS: Int?
    var hoverFocusAnimationMS: Int?
    var trackpadSettleAnimationMS: Int?
    var moveColumnAnimationMS: Int?
    var widthAnimationMS: Int?
    var animationCurve: AnimationCurve?
    var hoverToFocus: Bool?
    var hoverFocusDelayMS: Int?
    var hoverFocusMaxScrollRatio: CGFloat?
    var hoverFocusRequiresVisibleRatio: CGFloat?
    var hoverFocusEdgeTriggerWidth: CGFloat?
    var hoverFocusAfterTrackpadMS: Int?
    var hoverFocusMode: HoverFocusMode?
    var workspaceAutoBackAndForth: Bool?
    var centerFocusedColumn: Bool?
    var focusAlignment: FocusAlignment?
    var newWindowPosition: NewWindowPosition?
    var innerGap: CGFloat?
    var outerGap: CGFloat?
    var parkedSliverWidth: CGFloat?
    var excludedKeybindings: [String]?
    var keybindings: [String: [String]]?
    var trackpadNavigation: Bool?
    var trackpadNavigationFingers: Int?
    var trackpadNavigationSensitivity: CGFloat?
    var trackpadNavigationDeceleration: CGFloat?
    var trackpadNavigationHoverSuppressionMS: Int?
    var trackpadNavigationMomentumMinVelocity: CGFloat?
    var trackpadNavigationVelocityGain: CGFloat?
    var trackpadNavigationSettleAnimationMS: Int?
    var trackpadNavigationSnap: TrackpadNavigationSnap?
    var trackpadNavigationInvertX: Bool?
    var trackpadNavigationInvertY: Bool?
    var rescanIntervalMS: Int?
    var restoreOnExit: Bool?
    var persistLayout: Bool?
    var statePath: String?
    var hideMethod: HideMethod?
    var debugLogging: Bool?
    var rules: [WindowRule]

    static let fallback = MiriConfig(
        defaultWidthRatio: 0.8,
        presetWidthRatios: [0.5, 0.67, 0.8, 1.0],
        animationDurationMS: 240,
        keyboardAnimationMS: 240,
        hoverFocusAnimationMS: 240,
        trackpadSettleAnimationMS: 240,
        moveColumnAnimationMS: 240,
        widthAnimationMS: 280,
        animationCurve: .smooth,
        hoverToFocus: true,
        hoverFocusDelayMS: 120,
        hoverFocusMaxScrollRatio: 0.15,
        hoverFocusRequiresVisibleRatio: 0.15,
        hoverFocusEdgeTriggerWidth: 8,
        hoverFocusAfterTrackpadMS: 280,
        hoverFocusMode: .edgeOrVisible,
        workspaceAutoBackAndForth: true,
        centerFocusedColumn: true,
        focusAlignment: .smart,
        newWindowPosition: .afterActive,
        innerGap: 0,
        outerGap: 0,
        parkedSliverWidth: 1,
        excludedKeybindings: ["lalt+shift+5"],
        keybindings: defaultKeybindings,
        trackpadNavigation: true,
        trackpadNavigationFingers: 3,
        trackpadNavigationSensitivity: 1.6,
        trackpadNavigationDeceleration: 5.5,
        trackpadNavigationHoverSuppressionMS: 280,
        trackpadNavigationMomentumMinVelocity: 80,
        trackpadNavigationVelocityGain: 1.35,
        trackpadNavigationSettleAnimationMS: 240,
        trackpadNavigationSnap: .nearestColumn,
        trackpadNavigationInvertX: false,
        trackpadNavigationInvertY: false,
        rescanIntervalMS: 1000,
        restoreOnExit: true,
        persistLayout: true,
        statePath: nil,
        hideMethod: .skyLightAlpha,
        debugLogging: false,
        rules: [
            WindowRule(bundleID: "com.apple.finder", behavior: .ignore),
        ]
    )

    static let defaultKeybindings: [String: [String]] = [
        "focus_workspace_1": ["lalt+1"],
        "focus_workspace_2": ["lalt+2"],
        "focus_workspace_3": ["lalt+3"],
        "focus_workspace_4": ["lalt+4"],
        "focus_workspace_5": ["lalt+5"],
        "focus_workspace_6": ["lalt+6"],
        "focus_workspace_7": ["lalt+7"],
        "focus_workspace_8": ["lalt+8"],
        "focus_workspace_9": ["lalt+9"],
        "focus_previous_workspace": ["lalt+0"],
        "workspace_down": ["lalt+j"],
        "workspace_up": ["lalt+k"],
        "column_left": ["lalt+h"],
        "column_right": ["lalt+l"],
        "column_first": ["lalt+[", "lalt+home"],
        "column_last": ["lalt+]", "lalt+end"],
        "move_column_to_workspace_1": ["lalt+shift+1"],
        "move_column_to_workspace_2": ["lalt+shift+2"],
        "move_column_to_workspace_3": ["lalt+shift+3"],
        "move_column_to_workspace_4": ["lalt+shift+4"],
        "move_column_to_workspace_5": ["lalt+shift+5"],
        "move_column_to_workspace_6": ["lalt+shift+6"],
        "move_column_to_workspace_7": ["lalt+shift+7"],
        "move_column_to_workspace_8": ["lalt+shift+8"],
        "move_column_to_workspace_9": ["lalt+shift+9"],
        "move_column_down": ["lalt+shift+j"],
        "move_column_up": ["lalt+shift+k"],
        "move_column_left": ["lalt+shift+h"],
        "move_column_right": ["lalt+shift+l"],
        "move_column_to_first": ["lalt+shift+[", "lalt+shift+home"],
        "move_column_to_last": ["lalt+shift+]", "lalt+shift+end"],
        "cycle_width_preset_backward": ["lalt+ctrl+h"],
        "cycle_width_preset_forward": ["lalt+ctrl+l"],
        "nudge_width_narrower": ["lalt+ctrl+-"],
        "nudge_width_wider": ["lalt+ctrl+="],
        "cycle_all_width_presets_backward": ["lalt+ctrl+shift+h"],
        "cycle_all_width_presets_forward": ["lalt+ctrl+shift+l"],
        "nudge_all_widths_narrower": ["lalt+ctrl+shift+-"],
        "nudge_all_widths_wider": ["lalt+ctrl+shift+="],
    ]

    static func load() -> MiriConfig {
        loadWithMetadata().config
    }

    static func loadWithMetadata(logLoaded: Bool = true, logErrors: Bool = true) -> LoadedMiriConfig {
        let candidates = configCandidates()
        let decoder = JSONDecoder()

        for url in candidates {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }

            do {
                let config = normalize(try decoder.decode(MiriConfig.self, from: data))
                if logLoaded {
                    print("miri: loaded config \(url.path)")
                }
                return LoadedMiriConfig(
                    config: config,
                    sourceURL: url,
                    sourceModificationDate: modificationDate(for: url)
                )
            } catch {
                if logErrors {
                    fputs("miri: failed to parse config \(url.path): \(error)\n", stderr)
                }
            }
        }

        return LoadedMiriConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
    }

    static func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private static func normalize(_ loadedConfig: MiriConfig) -> MiriConfig {
        var config = loadedConfig
        config.defaultWidthRatio = config.defaultWidthRatio.clampedWidthRatio
        config.presetWidthRatios = normalizeWidthPresets(config.presetWidthRatios)
        config.animationDurationMS = config.animationDurationMS.map { min(max($0, 0), 500) }
        config.keyboardAnimationMS = config.keyboardAnimationMS.map { min(max($0, 0), 500) }
        config.hoverFocusAnimationMS = config.hoverFocusAnimationMS.map { min(max($0, 0), 500) }
        config.trackpadSettleAnimationMS = config.trackpadSettleAnimationMS.map { min(max($0, 0), 500) }
        config.moveColumnAnimationMS = config.moveColumnAnimationMS.map { min(max($0, 0), 500) }
        config.widthAnimationMS = config.widthAnimationMS.map { min(max($0, 0), 500) }
        config.hoverFocusDelayMS = config.hoverFocusDelayMS.map { min(max($0, 0), 1000) }
        config.hoverFocusMaxScrollRatio = config.hoverFocusMaxScrollRatio.map { min(max($0, 0), 2) }
        config.hoverFocusRequiresVisibleRatio = config.hoverFocusRequiresVisibleRatio.map { min(max($0, 0), 2) }
        config.hoverFocusEdgeTriggerWidth = config.hoverFocusEdgeTriggerWidth.map { min(max($0, 0), 96) }
        config.hoverFocusAfterTrackpadMS = config.hoverFocusAfterTrackpadMS.map { min(max($0, 0), 2000) }
        config.innerGap = config.innerGap.map { min(max($0, 0), 96) }
        config.outerGap = config.outerGap.map { min(max($0, 0), 96) }
        config.parkedSliverWidth = config.parkedSliverWidth.map { min(max($0, 0), 32) }
        config.trackpadNavigationFingers = config.trackpadNavigationFingers.map { min(max($0, 2), 5) }
        config.trackpadNavigationSensitivity = config.trackpadNavigationSensitivity.map { min(max($0, 0.1), 20) }
        config.trackpadNavigationDeceleration = config.trackpadNavigationDeceleration.map { min(max($0, 1), 30) }
        config.trackpadNavigationHoverSuppressionMS = config.trackpadNavigationHoverSuppressionMS.map { min(max($0, 0), 2000) }
        config.trackpadNavigationMomentumMinVelocity = config.trackpadNavigationMomentumMinVelocity.map { min(max($0, 0), 5000) }
        config.trackpadNavigationVelocityGain = config.trackpadNavigationVelocityGain.map { min(max($0, 0), 5) }
        config.trackpadNavigationSettleAnimationMS = config.trackpadNavigationSettleAnimationMS.map { min(max($0, 0), 500) }
        config.rescanIntervalMS = config.rescanIntervalMS.map { min(max($0, 100), 5000) }
        config.rules = config.rules.map { rule in
            var rule = rule
            rule.widthRatio = rule.widthRatio.map(\.clampedWidthRatio)
            rule.workspace = rule.workspace.map { min(max($0, 1), 99) }
            return rule
        }
        return config
    }

    private static func normalizeWidthPresets(_ presets: [CGFloat]?) -> [CGFloat]? {
        guard let presets else {
            return nil
        }

        let sorted = presets
            .filter(\.isFinite)
            .map(\.clampedManualWidthRatio)
            .sorted()
        var unique: [CGFloat] = []
        for preset in sorted where unique.last.map({ abs($0 - preset) >= 0.005 }) ?? true {
            unique.append(preset)
        }
        return unique.isEmpty ? nil : unique
    }

    private static func configCandidates() -> [URL] {
        var urls: [URL] = []

        if let path = ProcessInfo.processInfo.environment["MIRI_CONFIG"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }

        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("miri.config.json"))

        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        urls.append(xdgConfig.appendingPathComponent("miri/config.json"))

        return urls
    }

    private enum CodingKeys: String, CodingKey {
        case defaultWidthRatio = "default_width_ratio"
        case presetWidthRatios = "preset_width_ratios"
        case animationDurationMS = "animation_duration_ms"
        case keyboardAnimationMS = "keyboard_animation_ms"
        case hoverFocusAnimationMS = "hover_focus_animation_ms"
        case trackpadSettleAnimationMS = "trackpad_settle_animation_ms"
        case moveColumnAnimationMS = "move_column_animation_ms"
        case widthAnimationMS = "width_animation_ms"
        case animationCurve = "animation_curve"
        case hoverToFocus = "hover_to_focus"
        case hoverFocusDelayMS = "hover_focus_delay_ms"
        case hoverFocusMaxScrollRatio = "hover_focus_max_scroll_ratio"
        case hoverFocusRequiresVisibleRatio = "hover_focus_requires_visible_ratio"
        case hoverFocusEdgeTriggerWidth = "hover_focus_edge_trigger_width"
        case hoverFocusAfterTrackpadMS = "hover_focus_after_trackpad_ms"
        case hoverFocusMode = "hover_focus_mode"
        case workspaceAutoBackAndForth = "workspace_auto_back_and_forth"
        case centerFocusedColumn = "center_focused_column"
        case focusAlignment = "focus_alignment"
        case newWindowPosition = "new_window_position"
        case innerGap = "inner_gap"
        case outerGap = "outer_gap"
        case parkedSliverWidth = "parked_sliver_width"
        case excludedKeybindings = "excluded_keybindings"
        case keybindings
        case trackpadNavigation = "trackpad_navigation"
        case trackpadNavigationFingers = "trackpad_navigation_fingers"
        case trackpadNavigationSensitivity = "trackpad_navigation_sensitivity"
        case trackpadNavigationDeceleration = "trackpad_navigation_deceleration"
        case trackpadNavigationHoverSuppressionMS = "trackpad_navigation_hover_suppression_ms"
        case trackpadNavigationMomentumMinVelocity = "trackpad_navigation_momentum_min_velocity"
        case trackpadNavigationVelocityGain = "trackpad_navigation_velocity_gain"
        case trackpadNavigationSettleAnimationMS = "trackpad_navigation_settle_animation_ms"
        case trackpadNavigationSnap = "trackpad_navigation_snap"
        case trackpadNavigationInvertX = "trackpad_navigation_invert_x"
        case trackpadNavigationInvertY = "trackpad_navigation_invert_y"
        case rescanIntervalMS = "rescan_interval_ms"
        case restoreOnExit = "restore_on_exit"
        case persistLayout = "persist_layout"
        case statePath = "state_path"
        case hideMethod = "hide_method"
        case debugLogging = "debug_logging"
        case rules
    }
}

struct WindowRule: Codable {
    var bundleID: String?
    var appName: String?
    var titleContains: String?
    var behavior: WindowBehavior?
    var widthRatio: CGFloat?
    var workspace: Int?
    var openPosition: NewWindowPosition?
    var trackpadNavigation: Bool?
    var hoverToFocus: Bool?

    init(
        bundleID: String? = nil,
        appName: String? = nil,
        titleContains: String? = nil,
        behavior: WindowBehavior? = nil,
        widthRatio: CGFloat? = nil,
        workspace: Int? = nil,
        openPosition: NewWindowPosition? = nil,
        trackpadNavigation: Bool? = nil,
        hoverToFocus: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.titleContains = titleContains
        self.behavior = behavior
        self.widthRatio = widthRatio
        self.workspace = workspace
        self.openPosition = openPosition
        self.trackpadNavigation = trackpadNavigation
        self.hoverToFocus = hoverToFocus
    }

    func matches(_ window: ManagedWindow) -> Bool {
        if let bundleID, window.bundleID != bundleID {
            return false
        }
        if let appName, window.appName != appName {
            return false
        }
        if let titleContains,
           window.title.range(of: titleContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        {
            return false
        }
        return bundleID != nil || appName != nil || titleContains != nil
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case appName = "app_name"
        case titleContains = "title_contains"
        case behavior
        case widthRatio = "width_ratio"
        case workspace
        case openPosition = "open_position"
        case trackpadNavigation = "trackpad_navigation"
        case hoverToFocus = "hover_to_focus"
    }
}

extension CGFloat {
    var clampedWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.2), 2.0)
    }

    var clampedManualWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.05), 2.0)
    }
}
