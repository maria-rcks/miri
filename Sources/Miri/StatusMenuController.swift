import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var miri: Miri?
    private let menu = NSMenu()
    private let workspaceItem = NSMenuItem(title: "Workspace: —", action: nil, keyEquivalent: "")
    private let focusedItem = NSMenuItem(title: "Focused: —", action: nil, keyEquivalent: "")
    private let widthItem = NSMenuItem(title: "Width: —", action: nil, keyEquivalent: "")

    init(miri: Miri) {
        self.miri = miri
        super.init()
        configureMenu()
    }

    private func configureMenu() {
        statusItem.button?.title = "Miri"
        menu.delegate = self

        workspaceItem.isEnabled = false
        focusedItem.isEnabled = false
        widthItem.isEnabled = false

        menu.addItem(workspaceItem)
        menu.addItem(focusedItem)
        menu.addItem(widthItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Rescan Windows", action: #selector(rescanWindows), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Miri", action: #selector(quitMiri), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let status = miri?.currentStatus() else {
            return
        }

        workspaceItem.title = "Workspace: \(status.workspace) of \(status.workspaceCount)"
        focusedItem.title = "Focused: \(status.focusedWindow)"
        widthItem.title = status.widthPercent.map { "Width: \($0)%" } ?? "Width: —"
    }

    @objc private func openSettings() {
        miri?.showSettingsFromMenu()
    }

    @objc private func openConfig() {
        miri?.openConfigFromMenu()
    }

    @objc private func reloadConfig() {
        miri?.reloadFromMenu()
    }

    @objc private func rescanWindows() {
        miri?.rescanFromMenu()
    }

    @objc private func quitMiri() {
        miri?.quitFromMenu()
    }
}
