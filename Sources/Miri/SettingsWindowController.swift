import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var miri: Miri?
    private var draft: MiriConfig
    private var availableApps: [RuleAppInfo]
    private let tabView = NSTabView()
    private let rulesTable = NSTableView()

    private var controls: [String: NSControl] = [:]

    init(miri: Miri, config: MiriConfig, availableApps: [RuleAppInfo]) {
        self.miri = miri
        self.draft = config
        self.availableApps = availableApps

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Miri Settings"
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(config: MiriConfig, availableApps: [RuleAppInfo]) {
        draft = config
        self.availableApps = availableApps
        rebuildTabs()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonRow)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(button("Cancel", #selector(cancel)))
        buttonRow.addArrangedSubview(button("Apply", #selector(apply)))
        buttonRow.addArrangedSubview(button("Save", #selector(save)))

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),
            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            buttonRow.heightAnchor.constraint(equalToConstant: 32),
        ])

        rebuildTabs()
    }

    private func rebuildTabs() {
        controls.removeAll()
        tabView.tabViewItems.removeAll()
        tabView.addTabViewItem(tab("General", generalView()))
        tabView.addTabViewItem(tab("Layout", layoutView()))
        tabView.addTabViewItem(tab("Focus", focusView()))
        tabView.addTabViewItem(tab("Animations", animationsView()))
        tabView.addTabViewItem(tab("Trackpad", trackpadView()))
        tabView.addTabViewItem(tab("Rules", rulesView()))
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        return item
    }

    private func form(_ rows: [(String, NSView)]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        for (label, view) in rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false

            let text = NSTextField(labelWithString: label)
            text.alignment = .right
            text.widthAnchor.constraint(equalToConstant: 240).isActive = true
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            row.addArrangedSubview(text)
            row.addArrangedSubview(view)
            stack.addArrangedSubview(row)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: 720),
            document.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])

        scroll.documentView = document
        return scroll
    }

    private func generalView() -> NSView { form([
        ("Restore windows on quit", checkbox("restoreOnExit", draft.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true)),
        ("Persist layout", checkbox("persistLayout", draft.persistLayout ?? MiriConfig.fallback.persistLayout ?? true)),
        ("Rescan interval ms", intField("rescanIntervalMS", draft.rescanIntervalMS ?? MiriConfig.fallback.rescanIntervalMS ?? 1000)),
        ("Hide method", popup("hideMethod", HideMethod.allCasesStrings, draft.hideMethod?.rawValue ?? MiriConfig.fallback.hideMethod?.rawValue ?? "skylight_alpha")),
        ("Debug logging", checkbox("debugLogging", draft.debugLogging ?? MiriConfig.fallback.debugLogging ?? false)),
    ]) }

    private func layoutView() -> NSView { form([
        ("Default width ratio", doubleField("defaultWidthRatio", Double(draft.defaultWidthRatio))),
        ("Preset width ratios CSV", textField("presetWidthRatios", (draft.presetWidthRatios ?? []).map { String(format: "%.2f", Double($0)) }.joined(separator: ", "))),
        ("Focus alignment", popup("focusAlignment", FocusAlignment.allCasesStrings, draft.focusAlignment?.rawValue ?? "smart")),
        ("New window position", popup("newWindowPosition", NewWindowPosition.allCasesStrings, draft.newWindowPosition?.rawValue ?? "after_active")),
        ("Inner gap", doubleField("innerGap", Double(draft.innerGap ?? 0))),
        ("Outer gap", doubleField("outerGap", Double(draft.outerGap ?? 0))),
        ("Parked sliver width", doubleField("parkedSliverWidth", Double(draft.parkedSliverWidth ?? 1))),
    ]) }

    private func focusView() -> NSView { form([
        ("Hover to focus", checkbox("hoverToFocus", draft.hoverToFocus ?? true)),
        ("Hover delay ms", intField("hoverFocusDelayMS", draft.hoverFocusDelayMS ?? 120)),
        ("Hover mode", popup("hoverFocusMode", HoverFocusMode.allCasesStrings, draft.hoverFocusMode?.rawValue ?? "edge_or_visible")),
        ("Hover max scroll ratio", doubleField("hoverFocusMaxScrollRatio", Double(draft.hoverFocusMaxScrollRatio ?? 0.15))),
        ("Hover visible ratio", doubleField("hoverFocusRequiresVisibleRatio", Double(draft.hoverFocusRequiresVisibleRatio ?? 0.15))),
        ("Hover edge trigger width", doubleField("hoverFocusEdgeTriggerWidth", Double(draft.hoverFocusEdgeTriggerWidth ?? 8))),
        ("Hover after trackpad ms", intField("hoverFocusAfterTrackpadMS", draft.hoverFocusAfterTrackpadMS ?? 280)),
    ]) }

    private func animationsView() -> NSView { form([
        ("Animation duration ms", intField("animationDurationMS", draft.animationDurationMS ?? 0)),
        ("Keyboard animation ms", intField("keyboardAnimationMS", draft.keyboardAnimationMS ?? 0)),
        ("Hover focus animation ms", intField("hoverFocusAnimationMS", draft.hoverFocusAnimationMS ?? 0)),
        ("Trackpad settle animation ms", intField("trackpadSettleAnimationMS", draft.trackpadSettleAnimationMS ?? 0)),
        ("Move column animation ms", intField("moveColumnAnimationMS", draft.moveColumnAnimationMS ?? 0)),
        ("Width animation ms", intField("widthAnimationMS", draft.widthAnimationMS ?? 0)),
        ("Animation FPS", intField("animationFPS", draft.animationFPS ?? 30)),
        ("Pixel threshold", doubleField("animationPixelThreshold", Double(draft.animationPixelThreshold ?? 2))),
        ("Curve", popup("animationCurve", AnimationCurve.allCasesStrings, draft.animationCurve?.rawValue ?? "smooth")),
    ]) }

    private func trackpadView() -> NSView { form([
        ("Trackpad navigation", checkbox("trackpadNavigation", draft.trackpadNavigation ?? false)),
        ("Fingers", intField("trackpadNavigationFingers", draft.trackpadNavigationFingers ?? 3)),
        ("Sensitivity", doubleField("trackpadNavigationSensitivity", Double(draft.trackpadNavigationSensitivity ?? 1.6))),
        ("Deceleration", doubleField("trackpadNavigationDeceleration", Double(draft.trackpadNavigationDeceleration ?? 5.5))),
        ("Momentum min velocity", doubleField("trackpadNavigationMomentumMinVelocity", Double(draft.trackpadNavigationMomentumMinVelocity ?? 80))),
        ("Velocity gain", doubleField("trackpadNavigationVelocityGain", Double(draft.trackpadNavigationVelocityGain ?? 1.35))),
        ("Settle animation ms", intField("trackpadNavigationSettleAnimationMS", draft.trackpadNavigationSettleAnimationMS ?? 240)),
        ("Snap", popup("trackpadNavigationSnap", TrackpadNavigationSnap.allCasesStrings, draft.trackpadNavigationSnap?.rawValue ?? "nearest_column")),
        ("Invert X", checkbox("trackpadNavigationInvertX", draft.trackpadNavigationInvertX ?? false)),
        ("Invert Y", checkbox("trackpadNavigationInvertY", draft.trackpadNavigationInvertY ?? false)),
    ]) }

    private func rulesView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(button("Add Manual Rule", #selector(addManualRule)))
        buttons.addArrangedSubview(button("Add From Open App…", #selector(addFromOpenApp)))
        buttons.addArrangedSubview(button("Delete", #selector(deleteRule)))
        root.addArrangedSubview(buttons)

        rulesTable.dataSource = self
        rulesTable.delegate = self
        rulesTable.target = self
        rulesTable.doubleAction = #selector(editSelectedRule)
        rulesTable.usesAlternatingRowBackgroundColors = true
        rulesTable.headerView = nil
        rulesTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rule")))
        let scroll = NSScrollView()
        scroll.documentView = rulesTable
        scroll.hasVerticalScroller = true
        root.addArrangedSubview(scroll)
        rulesTable.reloadData()
        return root
    }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.rules.indices.contains(row) else { return nil }
        let rule = draft.rules[row]
        let text = NSTextField(labelWithString: ruleSummary(rule))
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    private func ruleSummary(_ rule: WindowRule) -> String {
        let match = rule.bundleID ?? rule.appName ?? rule.titleContains ?? "manual"
        let behavior = rule.behavior?.rawValue ?? "default"
        let width = rule.widthRatio.map { " width=\($0)" } ?? ""
        let workspace = rule.workspace.map { " workspace=\($0)" } ?? ""
        return "\(match) → \(behavior)\(width)\(workspace)"
    }

    private func readControlsIntoDraft() {
        draft.restoreOnExit = bool("restoreOnExit")
        draft.persistLayout = bool("persistLayout")
        draft.rescanIntervalMS = int("rescanIntervalMS")
        draft.hideMethod = HideMethod(rawValue: string("hideMethod"))
        draft.debugLogging = bool("debugLogging")
        draft.defaultWidthRatio = CGFloat(double("defaultWidthRatio"))
        draft.presetWidthRatios = string("presetWidthRatios").split(separator: ",").compactMap { CGFloat(Double($0.trimmingCharacters(in: .whitespaces)) ?? .nan) }
        draft.focusAlignment = FocusAlignment(rawValue: string("focusAlignment"))
        draft.newWindowPosition = NewWindowPosition(rawValue: string("newWindowPosition"))
        draft.innerGap = CGFloat(double("innerGap"))
        draft.outerGap = CGFloat(double("outerGap"))
        draft.parkedSliverWidth = CGFloat(double("parkedSliverWidth"))
        draft.hoverToFocus = bool("hoverToFocus")
        draft.hoverFocusDelayMS = int("hoverFocusDelayMS")
        draft.hoverFocusMode = HoverFocusMode(rawValue: string("hoverFocusMode"))
        draft.hoverFocusMaxScrollRatio = CGFloat(double("hoverFocusMaxScrollRatio"))
        draft.hoverFocusRequiresVisibleRatio = CGFloat(double("hoverFocusRequiresVisibleRatio"))
        draft.hoverFocusEdgeTriggerWidth = CGFloat(double("hoverFocusEdgeTriggerWidth"))
        draft.hoverFocusAfterTrackpadMS = int("hoverFocusAfterTrackpadMS")
        draft.animationDurationMS = int("animationDurationMS")
        draft.keyboardAnimationMS = int("keyboardAnimationMS")
        draft.hoverFocusAnimationMS = int("hoverFocusAnimationMS")
        draft.trackpadSettleAnimationMS = int("trackpadSettleAnimationMS")
        draft.moveColumnAnimationMS = int("moveColumnAnimationMS")
        draft.widthAnimationMS = int("widthAnimationMS")
        draft.animationFPS = int("animationFPS")
        draft.animationPixelThreshold = CGFloat(double("animationPixelThreshold"))
        draft.animationCurve = AnimationCurve(rawValue: string("animationCurve"))
        draft.trackpadNavigation = bool("trackpadNavigation")
        draft.trackpadNavigationFingers = int("trackpadNavigationFingers")
        draft.trackpadNavigationSensitivity = CGFloat(double("trackpadNavigationSensitivity"))
        draft.trackpadNavigationDeceleration = CGFloat(double("trackpadNavigationDeceleration"))
        draft.trackpadNavigationMomentumMinVelocity = CGFloat(double("trackpadNavigationMomentumMinVelocity"))
        draft.trackpadNavigationVelocityGain = CGFloat(double("trackpadNavigationVelocityGain"))
        draft.trackpadNavigationSettleAnimationMS = int("trackpadNavigationSettleAnimationMS")
        draft.trackpadNavigationSnap = TrackpadNavigationSnap(rawValue: string("trackpadNavigationSnap"))
        draft.trackpadNavigationInvertX = bool("trackpadNavigationInvertX")
        draft.trackpadNavigationInvertY = bool("trackpadNavigationInvertY")
    }

    @objc private func addManualRule() {
        draft.rules.append(WindowRule(bundleID: "", behavior: .tile))
        editRule(at: draft.rules.count - 1)
    }

    @objc private func addFromOpenApp() {
        let alert = NSAlert()
        alert.messageText = "Add Rule From Open App"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        popup.addItem(withTitle: "Manual bundle id…")
        for app in availableApps {
            popup.addItem(withTitle: "\(app.appName) — \(app.bundleID)")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if popup.indexOfSelectedItem == 0 {
            draft.rules.append(WindowRule(bundleID: "", behavior: .tile))
        } else {
            let app = availableApps[popup.indexOfSelectedItem - 1]
            draft.rules.append(WindowRule(bundleID: app.bundleID, appName: app.appName, behavior: .tile))
        }
        editRule(at: draft.rules.count - 1)
    }

    @objc private func editSelectedRule() {
        editRule(at: rulesTable.selectedRow)
    }

    @objc private func deleteRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.remove(at: row)
        rulesTable.reloadData()
    }

    private func editRule(at index: Int) {
        guard draft.rules.indices.contains(index) else { return }
        var rule = draft.rules[index]
        let alert = NSAlert()
        alert.messageText = "Edit Rule"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bundle = NSTextField(string: rule.bundleID ?? "")
        let app = NSTextField(string: rule.appName ?? "")
        let title = NSTextField(string: rule.titleContains ?? "")
        let width = NSTextField(string: rule.widthRatio.map { String(Double($0)) } ?? "")
        let workspace = NSTextField(string: rule.workspace.map(String.init) ?? "")
        let behavior = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 26), pullsDown: false)
        behavior.addItems(withTitles: ["Default", "Tile", "Float", "Ignore"])
        switch rule.behavior {
        case .tile: behavior.selectItem(withTitle: "Tile")
        case .float: behavior.selectItem(withTitle: "Float")
        case .ignore: behavior.selectItem(withTitle: "Ignore")
        case nil: behavior.selectItem(withTitle: "Default")
        }

        for field in [bundle, app, title, width, workspace] {
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        behavior.widthAnchor.constraint(equalToConstant: 300).isActive = true

        addRuleEditorRow(label: "Bundle ID", control: bundle, to: stack)
        addRuleEditorRow(label: "App Name", control: app, to: stack)
        addRuleEditorRow(label: "Title Contains", control: title, to: stack)
        addRuleEditorRow(label: "Behavior", control: behavior, to: stack)
        addRuleEditorRow(label: "Width Ratio", control: width, to: stack)
        addRuleEditorRow(label: "Workspace", control: workspace, to: stack)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 230))
        accessory.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: accessory.bottomAnchor),
        ])

        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        rule.bundleID = bundle.stringValue.isEmpty ? nil : bundle.stringValue
        rule.appName = app.stringValue.isEmpty ? nil : app.stringValue
        rule.titleContains = title.stringValue.isEmpty ? nil : title.stringValue
        switch behavior.titleOfSelectedItem {
        case "Tile": rule.behavior = .tile
        case "Float": rule.behavior = .float
        case "Ignore": rule.behavior = .ignore
        default: rule.behavior = nil
        }
        rule.widthRatio = Double(width.stringValue).map { CGFloat($0) }
        rule.workspace = Int(workspace.stringValue)
        draft.rules[index] = rule
        rulesTable.reloadData()
    }

    private func addRuleEditorRow(label: String, control: NSView, to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(labelView)
        row.addArrangedSubview(control)
        stack.addArrangedSubview(row)
    }

    @objc private func cancel() { close() }
    @objc private func apply() { readControlsIntoDraft(); miri?.saveConfigFromSettings(draft) }
    @objc private func save() { apply(); close() }

    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); return b }
    private func checkbox(_ key: String, _ value: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: "", target: nil, action: nil); b.state = value ? .on : .off; controls[key] = b; return b }
    private func textField(_ key: String, _ value: String) -> NSTextField { let f = NSTextField(string: value); f.widthAnchor.constraint(equalToConstant: 220).isActive = true; controls[key] = f; return f }
    private func intField(_ key: String, _ value: Int) -> NSTextField { textField(key, String(value)) }
    private func doubleField(_ key: String, _ value: Double) -> NSTextField { textField(key, String(value)) }
    private func popup(_ key: String, _ values: [String], _ selected: String) -> NSPopUpButton { let p = NSPopUpButton(); p.addItems(withTitles: values); p.selectItem(withTitle: selected); controls[key] = p; return p }
    private func bool(_ key: String) -> Bool { (controls[key] as? NSButton)?.state == .on }
    private func string(_ key: String) -> String { if let p = controls[key] as? NSPopUpButton { return p.titleOfSelectedItem ?? "" }; return (controls[key] as? NSTextField)?.stringValue ?? "" }
    private func int(_ key: String) -> Int { Int(string(key)) ?? 0 }
    private func double(_ key: String) -> Double { Double(string(key)) ?? 0 }
}

extension HideMethod { static let allCasesStrings = ["skylight_alpha", "park_only"] }
extension FocusAlignment { static let allCasesStrings = ["left", "center", "smart"] }
extension NewWindowPosition { static let allCasesStrings = ["before_active", "after_active", "end"] }
extension HoverFocusMode { static let allCasesStrings = ["off", "visible_only", "edge_or_visible"] }
extension AnimationCurve { static let allCasesStrings = ["smooth", "snappy", "linear"] }
extension TrackpadNavigationSnap { static let allCasesStrings = ["nearest_column", "nearest_visible", "none"] }
