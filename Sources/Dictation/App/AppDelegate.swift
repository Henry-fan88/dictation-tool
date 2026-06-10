import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusController: StatusItemController!
    private var controller: DictationController!
    private let fnMonitor = FnKeyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.loadOrCreate()

        controller = DictationController(config: config)
        statusController = StatusItemController()

        controller.onStateChange = { [weak self] state in
            self?.statusController.update(state)
        }

        statusController.onToggle = { [weak self] in self?.controller.toggle() }
        statusController.onOpenConfig = { ConfigStore.openInEditor() }
        statusController.onReload = { [weak self] in
            let fresh = ConfigStore.loadOrCreate()
            self?.controller.updateConfig(fresh)
            self?.fnMonitor.suppressDefault = fresh.hotkey.suppressFnDefault
            self?.statusController.update(.idle)
            self?.controller.ensureLocalSetupIfNeeded()
        }
        statusController.onCheckPermissions = { [weak self] in self?.requestPermissions() }

        fnMonitor.suppressDefault = config.hotkey.suppressFnDefault
        fnMonitor.onToggle = { [weak self] in self?.controller.toggle() }

        requestPermissions()
        Permissions.requestSpeech { _ in }
        startFnMonitorWithRetry()
        controller.ensureLocalSetupIfNeeded()
    }

    /// The event tap can only be created once Accessibility is granted, which
    /// the user may do after launch — so keep retrying until it sticks.
    private func startFnMonitorWithRetry() {
        if fnMonitor.start() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startFnMonitorWithRetry()
        }
    }

    private func requestPermissions() {
        if !Permissions.accessibilityEnabled() {
            Permissions.promptAccessibility()
        }
        Permissions.ensureMic { _ in }
    }
}
