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
        tabView.addTabViewItem(tab("Keybindings", keybindingsView()))
        tabView.addTabViewItem(tab("Workspace Bar", workspaceBarView()))
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
        ("Strategy", popup("animationStrategy", AnimationStrategy.allCasesStrings, draft.animationStrategy?.rawValue ?? MiriConfig.fallback.animationStrategy?.rawValue ?? "snappy")),
        ("Animation FPS", intField("animationFPS", draft.animationFPS ?? 60)),
        ("Pixel threshold", doubleField("animationPixelThreshold", Double(draft.animationPixelThreshold ?? 0.5))),
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

    private func workspaceBarView() -> NSView { form([
        ("Highlight color", colorWell("workspaceBarHighlightColor", draft.workspaceBarHighlightColor ?? MiriConfig.fallback.workspaceBarHighlightColor ?? "yellow")),
        ("Visible app window icons", slider("workspaceBarVisibleIconCount", draft.workspaceBarVisibleIconCount ?? MiriConfig.fallback.workspaceBarVisibleIconCount ?? 3, min: 1, max: 6)),
        ("Overflow style", popup("workspaceBarOverflowStyle", WorkspaceBarOverflowStyle.allCasesStrings, draft.workspaceBarOverflowStyle?.rawValue ?? MiriConfig.fallback.workspaceBarOverflowStyle?.rawValue ?? "plus_count")),
    ]) }

    private func keybindingsView() -> NSView {
        var rows: [(String, NSView)] = []
        rows.append(("Excluded keybindings CSV", textField("excludedKeybindings", (draft.excludedKeybindings ?? []).joined(separator: ", "))))

        let keybindings = draft.keybindings ?? MiriConfig.defaultKeybindings
        for command in MiriConfig.defaultKeybindings.keys.sorted() {
            let bindings = keybindings[command] ?? []
            rows.append((command, textField("keybinding.\(command)", bindings.joined(separator: ", "))))
        }

        return form(rows)
    }

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
        buttons.addArrangedSubview(button("Duplicate", #selector(duplicateRule)))
        buttons.addArrangedSubview(button("Move Up", #selector(moveRuleUp)))
        buttons.addArrangedSubview(button("Move Down", #selector(moveRuleDown)))
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
        draft.animationStrategy = AnimationStrategy(rawValue: string("animationStrategy"))
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
        draft.workspaceBarHighlightColor = colorHex("workspaceBarHighlightColor")
        draft.workspaceBarVisibleIconCount = max(1, min(int("workspaceBarVisibleIconCount"), 6))
        draft.workspaceBarOverflowStyle = WorkspaceBarOverflowStyle(rawValue: string("workspaceBarOverflowStyle"))

        draft.excludedKeybindings = csv("excludedKeybindings")
        var keybindings: [String: [String]] = [:]
        for command in MiriConfig.defaultKeybindings.keys.sorted() {
            keybindings[command] = csv("keybinding.\(command)")
        }
        draft.keybindings = keybindings
    }

    private func validateDraft() -> String? {
        var seen: [String: String] = [:]
        let keybindings = draft.keybindings ?? [:]
        for command in keybindings.keys.sorted() {
            for binding in keybindings[command] ?? [] {
                let normalized = binding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                if let previous = seen[normalized] {
                    return "Keybinding '\(binding)' is assigned to both '\(previous)' and '\(command)'."
                }
                seen[normalized] = command
            }
        }
        return nil
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

    @objc private func duplicateRule() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row) else { return }
        draft.rules.insert(draft.rules[row], at: row + 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func moveRuleUp() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row > 0 else { return }
        draft.rules.swapAt(row, row - 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveRuleDown() {
        let row = rulesTable.selectedRow
        guard draft.rules.indices.contains(row), row < draft.rules.count - 1 else { return }
        draft.rules.swapAt(row, row + 1)
        rulesTable.reloadData()
        rulesTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
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

    @objc private func apply() {
        readControlsIntoDraft()
        if let validationError = validateDraft() {
            showAlert(title: "Invalid Settings", message: validationError)
            return
        }
        miri?.saveConfigFromSettings(draft)
        showAlert(title: "Miri Settings Saved", message: "Config was saved and reloaded.")
    }

    @objc private func save() {
        readControlsIntoDraft()
        if let validationError = validateDraft() {
            showAlert(title: "Invalid Settings", message: validationError)
            return
        }
        miri?.saveConfigFromSettings(draft)
        close()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); return b }
    private func checkbox(_ key: String, _ value: Bool) -> NSButton { let b = NSButton(checkboxWithTitle: "", target: nil, action: nil); b.state = value ? .on : .off; controls[key] = b; return b }
    private func textField(_ key: String, _ value: String) -> NSTextField { let f = NSTextField(string: value); f.widthAnchor.constraint(equalToConstant: 220).isActive = true; controls[key] = f; return f }
    private func intField(_ key: String, _ value: Int) -> NSTextField { textField(key, String(value)) }
    private func doubleField(_ key: String, _ value: Double) -> NSTextField { textField(key, String(value)) }
    private func popup(_ key: String, _ values: [String], _ selected: String) -> NSPopUpButton { let p = NSPopUpButton(); p.addItems(withTitles: values); p.selectItem(withTitle: selected); controls[key] = p; return p }

    private func slider(_ key: String, _ value: Int, min: Int, max: Int) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let slider = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max), target: self, action: #selector(sliderChanged(_:)))
        slider.numberOfTickMarks = max - min + 1
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        let label = NSTextField(labelWithString: "\(value)")
        label.widthAnchor.constraint(equalToConstant: 24).isActive = true
        label.identifier = NSUserInterfaceItemIdentifier("\(key).label")
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(label)
        controls[key] = slider
        return stack
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.integerValue = Int(sender.doubleValue.rounded())
        if let stack = sender.superview as? NSStackView,
           let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "\(key).label" }) {
            label.stringValue = "\(sender.integerValue)"
        }
    }

    private func colorWell(_ key: String, _ value: String) -> NSColorWell {
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
        well.color = colorFromSetting(value)
        controls[key] = well
        return well
    }

    private func bool(_ key: String) -> Bool { (controls[key] as? NSButton)?.state == .on }
    private func string(_ key: String) -> String { if let p = controls[key] as? NSPopUpButton { return p.titleOfSelectedItem ?? "" }; return (controls[key] as? NSTextField)?.stringValue ?? "" }
    private func csv(_ key: String) -> [String] { string(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func int(_ key: String) -> Int { if let s = controls[key] as? NSSlider { return s.integerValue }; return Int(string(key)) ?? 0 }
    private func double(_ key: String) -> Double { Double(string(key)) ?? 0 }

    private func colorHex(_ key: String) -> String {
        guard let color = (controls[key] as? NSColorWell)?.color.usingColorSpace(.sRGB) else { return "#FFD60A" }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func colorFromSetting(_ value: String) -> NSColor {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "mint": return .systemMint
        case "teal": return .systemTeal
        case "cyan": return .systemCyan
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "gray", "grey": return .systemGray
        case let hex where hex.hasPrefix("#"):
            return colorFromHex(hex) ?? .systemYellow
        default:
            return .systemYellow
        }
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        let trimmed = String(hex.dropFirst())
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

extension HideMethod { static let allCasesStrings = ["skylight_alpha", "park_only"] }
extension FocusAlignment { static let allCasesStrings = ["left", "center", "smart"] }
extension NewWindowPosition { static let allCasesStrings = ["before_active", "after_active", "end"] }
extension HoverFocusMode { static let allCasesStrings = ["off", "visible_only", "edge_or_visible"] }
extension AnimationCurve { static let allCasesStrings = ["smooth", "snappy", "linear"] }
extension AnimationStrategy { static let allCasesStrings = ["snapshot", "smooth_ax", "snappy", "off"] }
extension TrackpadNavigationSnap { static let allCasesStrings = ["nearest_column", "nearest_visible", "none"] }
extension WorkspaceBarOverflowStyle { static let allCasesStrings = ["plus_count", "dots_count", "chevron", "none"] }
