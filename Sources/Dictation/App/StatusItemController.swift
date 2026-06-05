import AppKit

/// The menu-bar item: a glyph that reflects state plus a small action menu.
final class StatusItemController: NSObject {

    var onToggle: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onReload: (() -> Void)?
    var onCheckPermissions: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start Dictation", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        configure()
        update(.idle)
    }

    private func configure() {
        statusItem.button?.title = "🎙️"

        let menu = NSMenu()

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem.target = self
        toggleItem.action = #selector(handleToggle)
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let openConfig = NSMenuItem(title: "Open Config File…", action: #selector(handleOpenConfig), keyEquivalent: ",")
        openConfig.target = self
        menu.addItem(openConfig)

        let reload = NSMenuItem(title: "Reload Config", action: #selector(handleReload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let perms = NSMenuItem(title: "Check Permissions", action: #selector(handleCheckPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Dictation", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func update(_ state: AppState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.title = "🎙️"
            statusLine.title = "Idle — press fn to dictate"
            toggleItem.title = "Start Dictation"
        case .recording:
            button.title = "🔴"
            statusLine.title = "Recording… press fn to stop"
            toggleItem.title = "Stop Dictation"
        case .transcribing:
            button.title = "⏳"
            statusLine.title = "Transcribing…"
            toggleItem.title = "Working…"
        case .organizing:
            button.title = "⏳"
            statusLine.title = "Organizing with LLM…"
            toggleItem.title = "Working…"
        case .inserting:
            button.title = "⌨️"
            statusLine.title = "Inserting text…"
            toggleItem.title = "Working…"
        case .error(let message):
            button.title = "⚠️"
            statusLine.title = "Error: \(message)"
            toggleItem.title = "Start Dictation"
        }
    }

    @objc private func handleToggle() { onToggle?() }
    @objc private func handleOpenConfig() { onOpenConfig?() }
    @objc private func handleReload() { onReload?() }
    @objc private func handleCheckPermissions() { onCheckPermissions?() }
    @objc private func handleQuit() { NSApp.terminate(nil) }
}
