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

enum MiriConfigLoadResult {
    case loaded(LoadedMiriConfig)
    case notFound
    case parseError(Error)
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
        excludedKeybindings: ["cmd+shift+5"],
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
            WindowRule(bundleID: "com.apple.finder", behavior: .float),
        ]
    )

    static let defaultKeybindings: [String: [String]] = [
        "focus_workspace_1": ["cmd+1"],
        "focus_workspace_2": ["cmd+2"],
        "focus_workspace_3": ["cmd+3"],
        "focus_workspace_4": ["cmd+4"],
        "focus_workspace_5": ["cmd+5"],
        "focus_workspace_6": ["cmd+6"],
        "focus_workspace_7": ["cmd+7"],
        "focus_workspace_8": ["cmd+8"],
        "focus_workspace_9": ["cmd+9"],
        "focus_previous_workspace": ["cmd+0"],
        "workspace_down": ["cmd+j"],
        "workspace_up": ["cmd+k"],
        "column_left": ["cmd+h"],
        "column_right": ["cmd+l"],
        "column_first": ["cmd+[", "cmd+home", "cmd+fn+left"],
        "column_last": ["cmd+]", "cmd+end", "cmd+fn+right"],
        "move_column_to_workspace_1": ["cmd+shift+1"],
        "move_column_to_workspace_2": ["cmd+shift+2"],
        "move_column_to_workspace_3": ["cmd+shift+3"],
        "move_column_to_workspace_4": ["cmd+shift+4"],
        "move_column_to_workspace_5": ["cmd+ctrl+shift+5"],
        "move_column_to_workspace_6": ["cmd+shift+6"],
        "move_column_to_workspace_7": ["cmd+shift+7"],
        "move_column_to_workspace_8": ["cmd+shift+8"],
        "move_column_to_workspace_9": ["cmd+shift+9"],
        "move_column_down": ["cmd+shift+j"],
        "move_column_up": ["cmd+shift+k"],
        "move_column_left": ["cmd+shift+h"],
        "move_column_right": ["cmd+shift+l"],
        "move_column_to_first": ["cmd+shift+[", "cmd+shift+home", "cmd+shift+fn+left"],
        "move_column_to_last": ["cmd+shift+]", "cmd+shift+end", "cmd+shift+fn+right"],
        "cycle_width_preset_backward": ["cmd+ctrl+h"],
        "cycle_width_preset_forward": ["cmd+ctrl+l"],
        "nudge_width_narrower": ["cmd+ctrl+-"],
        "nudge_width_wider": ["cmd+ctrl+="],
        "cycle_all_width_presets_backward": ["cmd+ctrl+shift+h"],
        "cycle_all_width_presets_forward": ["cmd+ctrl+shift+l"],
        "nudge_all_widths_narrower": ["cmd+ctrl+shift+-"],
        "nudge_all_widths_wider": ["cmd+ctrl+shift+="],
    ]

    static func load() -> MiriConfig {
        loadWithMetadata().config
    }

    static func loadWithMetadata(logLoaded: Bool = true, logErrors: Bool = true) -> LoadedMiriConfig {
        let explicitConfigURL = explicitConfigURL()
        let candidates = configCandidates(explicitConfigURL: explicitConfigURL)

        for url in candidates {
            switch load(from: url, logLoaded: logLoaded, logErrors: logErrors) {
            case let .loaded(loaded):
                return loaded
            case .notFound:
                continue
            case let .parseError(error):
                if url == explicitConfigURL {
                    if logErrors {
                        fputs("miri: explicit config \(url.path) is invalid; not falling back: \(error)\n", stderr)
                    }
                    return LoadedMiriConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
                }
                continue
            }
        }

        return LoadedMiriConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
    }

    static func load(from url: URL, logLoaded: Bool = true, logErrors: Bool = true) -> MiriConfigLoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return .notFound
        }

        do {
            let config = normalize(try JSONDecoder().decode(MiriConfig.self, from: data))
            if logLoaded {
                print("miri: loaded config \(url.path)")
            }
            let loaded = LoadedMiriConfig(
                config: config,
                sourceURL: url,
                sourceModificationDate: modificationDate(for: url)
            )
            return .loaded(loaded)
        } catch {
            if logErrors {
                fputs("miri: failed to parse config \(url.path): \(error)\n", stderr)
            }
            return .parseError(error)
        }
    }

    static func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    static func normalize(_ loadedConfig: MiriConfig) -> MiriConfig {
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

    private static func explicitConfigURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MIRI_CONFIG"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private static func configCandidates(explicitConfigURL: URL?) -> [URL] {
        var urls: [URL] = []

        if let explicitConfigURL {
            urls.append(explicitConfigURL)
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
