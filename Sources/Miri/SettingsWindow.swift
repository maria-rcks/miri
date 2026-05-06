import AppKit
import SwiftUI

@MainActor
final class MiriSettingsStore: ObservableObject {
    @Published var config: MiriConfig
    @Published var presetRatios: [CGFloat]
    @Published var statePathText: String
    @Published var errorMessage: String?
    @Published var savedMessage: String?

    let settingsURL: URL
    let stateURL: URL
    private let onSave: (MiriConfig) -> Bool
    private let onRevealSettings: () -> Void
    private let onRevealState: () -> Void
    private var pendingSave: DispatchWorkItem?

    init(
        config: MiriConfig,
        settingsURL: URL,
        stateURL: URL,
        onSave: @escaping (MiriConfig) -> Bool,
        onRevealSettings: @escaping () -> Void,
        onRevealState: @escaping () -> Void
    ) {
        self.config = config
        self.settingsURL = settingsURL
        self.stateURL = stateURL
        self.onSave = onSave
        self.onRevealSettings = onRevealSettings
        self.onRevealState = onRevealState
        presetRatios = MiriSettingsStore.normalizedPresets(
            config.presetWidthRatios ?? MiriConfig.fallback.presetWidthRatios ?? []
        )
        statePathText = config.statePath ?? ""
    }

    func save() {
        pendingSave?.cancel()
        var next = config
        next.presetWidthRatios = normalizedPresetRatios()
        next.statePath = statePathText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        guard errorMessage == nil else {
            NSSound.beep()
            return
        }

        if onSave(next) {
            config = next
            savedMessage = "Saved and applied"
        } else {
            savedMessage = nil
            errorMessage = "Could not save settings."
            NSSound.beep()
        }
    }

    func scheduleSave() {
        pendingSave?.cancel()
        savedMessage = nil

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.save()
            }
        }
        pendingSave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    func revealSettings() {
        onRevealSettings()
    }

    func revealState() {
        onRevealState()
    }

    func addPreset() {
        let next = min((presetRatios.last ?? config.defaultWidthRatio) + 0.1, 2.0)
        presetRatios.append(next.clampedManualWidthRatio)
        scheduleSave()
    }

    func removePreset(at index: Int) {
        guard presetRatios.indices.contains(index), presetRatios.count > 1 else {
            NSSound.beep()
            return
        }
        presetRatios.remove(at: index)
        scheduleSave()
    }

    func presetBinding(at index: Int) -> Binding<CGFloat> {
        Binding(
            get: {
                guard self.presetRatios.indices.contains(index) else {
                    return self.config.defaultWidthRatio
                }
                return self.presetRatios[index]
            },
            set: { newValue in
                guard self.presetRatios.indices.contains(index) else {
                    return
                }
                self.presetRatios[index] = newValue.clampedManualWidthRatio
                self.scheduleSave()
            }
        )
    }

    private func normalizedPresetRatios() -> [CGFloat]? {
        let normalized = Self.normalizedPresets(presetRatios)
        guard !normalized.isEmpty else {
            errorMessage = "Add at least one width preset."
            return nil
        }
        errorMessage = nil
        return normalized
    }

    private static func normalizedPresets(_ presets: [CGFloat]) -> [CGFloat] {
        let sorted = presets
            .filter(\.isFinite)
            .map(\.clampedManualWidthRatio)
            .sorted()
        var unique: [CGFloat] = []
        for preset in sorted where unique.last.map({ abs($0 - preset) >= 0.005 }) ?? true {
            unique.append(preset)
        }
        return unique
    }
}

private enum MiriSettingsPane: String, CaseIterable, Identifiable {
    case general
    case navigation
    case motion
    case files
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .navigation: "Navigation"
        case .motion: "Motion"
        case .files: "Files"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .navigation: "hand.draw"
        case .motion: "waveform.path"
        case .files: "folder"
        case .advanced: "gearshape.2"
        }
    }
}

struct MiriSettingsView: View {
    @StateObject private var store: MiriSettingsStore
    @State private var selection: MiriSettingsPane = .general

    init(
        config: MiriConfig,
        settingsURL: URL,
        stateURL: URL,
        onSave: @escaping (MiriConfig) -> Bool,
        onRevealSettings: @escaping () -> Void,
        onRevealState: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: MiriSettingsStore(
            config: config,
            settingsURL: settingsURL,
            stateURL: stateURL,
            onSave: onSave,
            onRevealSettings: onRevealSettings,
            onRevealState: onRevealState
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(MiriSettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
            .navigationTitle("Miri")
            .frame(minWidth: 170)
        } detail: {
            VStack(spacing: 0) {
                header
                Form {
                    selectedSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(selection.title)
                .font(.title3.weight(.semibold))

            Spacer(minLength: 12)
            statusMessage
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 0)
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch selection {
        case .general:
            layoutSection
            behaviorSection
        case .navigation:
            hoverSection
            trackpadSection
        case .motion:
            animationSection
        case .files:
            persistenceSection
        case .advanced:
            advancedSection
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let errorMessage = store.errorMessage {
            Text(errorMessage)
                .foregroundStyle(.red)
        } else if let savedMessage = store.savedMessage {
            Text(savedMessage)
                .foregroundStyle(.secondary)
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default width")
                    Spacer()
                    Text("\(Int(store.config.defaultWidthRatio * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { store.config.defaultWidthRatio },
                        set: {
                            store.config.defaultWidthRatio = $0.clampedWidthRatio
                            store.scheduleSave()
                        }
                    ),
                    in: 0.2 ... 2.0,
                    step: 0.05
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Width presets")
                ForEach(Array(store.presetRatios.indices), id: \.self) { index in
                    HStack(spacing: 12) {
                        Text(String(format: "%.2f", store.presetRatios[index]))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .leading)
                        Slider(value: store.presetBinding(at: index), in: 0.05 ... 2.0, step: 0.01)
                        Button("Remove") {
                            store.removePreset(at: index)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.presetRatios.count <= 1)
                    }
                }
                Button("Add Preset", action: store.addPreset)
                    .buttonStyle(.borderless)
                Text("Ratios used by width cycling commands.").settingsCaption()
            }

            numericSlider(
                title: "Inner gap",
                value: optionalCGFloatBinding(\.innerGap, fallback: MiriConfig.fallback.innerGap ?? 0),
                range: 0 ... 96,
                suffix: "pt"
            )
            numericSlider(
                title: "Outer gap",
                value: optionalCGFloatBinding(\.outerGap, fallback: MiriConfig.fallback.outerGap ?? 0),
                range: 0 ... 96,
                suffix: "pt"
            )
        }
    }

    private var behaviorSection: some View {
        Section("Window Behavior") {
            Picker(selection: optionalEnumBinding(\.focusAlignment, fallback: .smart)) {
                ForEach(FocusAlignment.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Focus alignment")
            }

            Picker(selection: optionalEnumBinding(\.newWindowPosition, fallback: .afterActive)) {
                ForEach(NewWindowPosition.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("New windows")
            }

            Toggle("Workspace back-and-forth", isOn: optionalBoolBinding(\.workspaceAutoBackAndForth, fallback: true))
        }
    }

    private var hoverSection: some View {
        Section("Hover Focus") {
            Toggle("Hover to focus", isOn: optionalBoolBinding(\.hoverToFocus, fallback: true))

            Picker(selection: optionalEnumBinding(\.hoverFocusMode, fallback: .edgeOrVisible)) {
                ForEach(HoverFocusMode.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Activation")
            }

            numericStepper(
                title: "Delay",
                value: optionalIntBinding(\.hoverFocusDelayMS, fallback: 120),
                range: 0 ... 1000,
                suffix: "ms"
            )
        }
    }

    private var trackpadSection: some View {
        Section("Trackpad") {
            Toggle("Three-finger navigation", isOn: optionalBoolBinding(\.trackpadNavigation, fallback: true))

            Stepper(value: optionalIntBinding(\.trackpadNavigationFingers, fallback: 3), in: 2 ... 5) {
                HStack {
                    Text("Fingers")
                    Spacer()
                    Text("\(store.config.trackpadNavigationFingers ?? 3)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(String(format: "%.1fx", store.config.trackpadNavigationSensitivity ?? 1.6))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: optionalCGFloatBinding(\.trackpadNavigationSensitivity, fallback: 1.6),
                    in: 0.1 ... 20,
                    step: 0.1
                )
            }

            Picker(selection: optionalEnumBinding(\.trackpadNavigationSnap, fallback: .nearestColumn)) {
                ForEach(TrackpadNavigationSnap.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Snap")
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Invert horizontal", isOn: optionalBoolBinding(\.trackpadNavigationInvertX, fallback: false))
                Toggle("Invert vertical", isOn: optionalBoolBinding(\.trackpadNavigationInvertY, fallback: false))
            }
        }
    }

    private var animationSection: some View {
        Section("Animation") {
            Picker(selection: optionalEnumBinding(\.animationCurve, fallback: .smooth)) {
                ForEach(AnimationCurve.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Curve")
            }

            numericStepper(
                title: "Default",
                value: optionalIntBinding(\.animationDurationMS, fallback: 240),
                range: 0 ... 500,
                suffix: "ms"
            )
            numericStepper(
                title: "Keyboard",
                value: optionalIntBinding(\.keyboardAnimationMS, fallback: 240),
                range: 0 ... 500,
                suffix: "ms"
            )
            numericStepper(
                title: "Width changes",
                value: optionalIntBinding(\.widthAnimationMS, fallback: 280),
                range: 0 ... 500,
                suffix: "ms"
            )
        }
    }

    private var persistenceSection: some View {
        Section("Files") {
            Toggle("Restore windows on exit", isOn: optionalBoolBinding(\.restoreOnExit, fallback: true))

            Toggle("Persist layout state", isOn: optionalBoolBinding(\.persistLayout, fallback: true))

            VStack(alignment: .leading, spacing: 4) {
                Text("Layout state path")
                TextField(store.stateURL.path, text: $store.statePathText)
                    .onChange(of: store.statePathText) { _ in store.scheduleSave() }
                Text("Leave blank to use Miri's default state location.").settingsCaption()
            }

            HStack {
                Button("Reveal Settings", action: store.revealSettings)
                Button("Reveal Layout State", action: store.revealState)
            }
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            Picker(selection: optionalEnumBinding(\.hideMethod, fallback: .skyLightAlpha)) {
                ForEach(HideMethod.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            } label: {
                Text("Parking method")
            }

            numericStepper(
                title: "Parked sliver",
                value: optionalCGFloatBinding(\.parkedSliverWidth, fallback: 1),
                range: 0 ... 32,
                suffix: "pt"
            )

            numericStepper(
                title: "Rescan interval",
                value: optionalIntBinding(\.rescanIntervalMS, fallback: 1000),
                range: 100 ... 5000,
                suffix: "ms"
            )

            Toggle("Debug logging", isOn: optionalBoolBinding(\.debugLogging, fallback: false))
        }
    }

    private func numericStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func numericStepper(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String
    ) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func numericSlider(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
        }
    }

    private func optionalBoolBinding(
        _ keyPath: WritableKeyPath<MiriConfig, Bool?>,
        fallback: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<MiriConfig, Int?>,
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalCGFloatBinding(
        _ keyPath: WritableKeyPath<MiriConfig, CGFloat?>,
        fallback: CGFloat
    ) -> Binding<CGFloat> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }

    private func optionalEnumBinding<Value>(
        _ keyPath: WritableKeyPath<MiriConfig, Value?>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? fallback },
            set: {
                store.config[keyPath: keyPath] = $0
                store.scheduleSave()
            }
        )
    }
}

private extension Text {
    func settingsCaption() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension FocusAlignment: CaseIterable {
    static var allCases: [FocusAlignment] { [.left, .center, .smart] }

    var displayName: String {
        switch self {
        case .left: "Left"
        case .center: "Center"
        case .smart: "Smart"
        }
    }
}

extension NewWindowPosition: CaseIterable {
    static var allCases: [NewWindowPosition] { [.beforeActive, .afterActive, .end] }

    var displayName: String {
        switch self {
        case .beforeActive: "Before active"
        case .afterActive: "After active"
        case .end: "End"
        }
    }
}

extension HideMethod: CaseIterable {
    static var allCases: [HideMethod] { [.skyLightAlpha, .parkOnly] }

    var displayName: String {
        switch self {
        case .skyLightAlpha: "SkyLight alpha"
        case .parkOnly: "Park only"
        }
    }
}

extension AnimationCurve: CaseIterable {
    static var allCases: [AnimationCurve] { [.smooth, .snappy, .linear] }

    var displayName: String {
        switch self {
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        case .linear: "Linear"
        }
    }
}

extension HoverFocusMode: CaseIterable {
    static var allCases: [HoverFocusMode] { [.off, .visibleOnly, .edgeOrVisible] }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .visibleOnly: "Visible only"
        case .edgeOrVisible: "Edge or visible"
        }
    }
}

extension TrackpadNavigationSnap: CaseIterable {
    static var allCases: [TrackpadNavigationSnap] { [.nearestColumn, .nearestVisible, .none] }

    var displayName: String {
        switch self {
        case .nearestColumn: "Nearest column"
        case .nearestVisible: "Nearest visible"
        case .none: "None"
        }
    }
}
