import AppKit
import ServiceManagement
import UserNotifications

final class Watch {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var ejecting = Set<String>()
    private var watches: [String: Watch] = [:]
    private var activity: [String] = []
    private var pendingReset: DispatchWorkItem?

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        refreshStatus()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let drives = mountedDrives()

        if drives.isEmpty {
            addDisabled("No external drives", to: menu)
        }
        for drive in drives {
            menu.addItem(item(for: drive))
        }

        menu.addItem(NSMenuItem.separator())

        if !activity.isEmpty {
            let recent = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            activity.forEach { addDisabled($0, to: submenu) }
            recent.submenu = submenu
            menu.addItem(recent)
        }

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        switch SMAppService.mainApp.status {
        case .enabled:
            login.state = .on
        case .requiresApproval:
            login.state = .mixed
        default:
            login.state = .off
        }
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Cast Off", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addDisabled(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func item(for drive: Drive) -> NSMenuItem {
        let item: NSMenuItem
        if ejecting.contains(drive.id) {
            item = NSMenuItem(title: "Ejecting \(drive.name)…", action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else if watches[drive.id] != nil {
            item = NSMenuItem(title: "Stop Waiting for \(drive.name)", action: #selector(cancelClicked(_:)), keyEquivalent: "")
            item.target = self
        } else {
            let prefix = drive.volumes.count > 1 ? "Eject Disk: " : "Eject "
            item = NSMenuItem(title: prefix + drive.name, action: #selector(ejectClicked(_:)), keyEquivalent: "")
            item.target = self
            if drive.volumes.count > 1 {
                item.toolTip = "These volumes share one physical disk, so they eject together."
            }
        }
        item.representedObject = drive
        item.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)
        return item
    }

    // MARK: Actions

    @objc private func ejectClicked(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? Drive else { return }
        ejecting.insert(drive.id)
        refreshStatus()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = performEject(drive)
            DispatchQueue.main.async {
                self.ejecting.remove(drive.id)
                self.finish(drive, outcome, afterWaiting: false)
            }
        }
    }

    @objc private func cancelClicked(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? Drive else { return }
        watches[drive.id]?.cancel()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showAlert(title: "Couldn't change Start at Login", message: error.localizedDescription)
        }
    }

    private func startWatching(_ drive: Drive) {
        guard watches[drive.id] == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let watch = Watch()
        watches[drive.id] = watch
        record("\(drive.name): waiting until it's free")
        refreshStatus()

        DispatchQueue.global(qos: .utility).async {
            let outcome = ejectWhenFree(drive, isCancelled: { watch.isCancelled })
            DispatchQueue.main.async {
                self.watches[drive.id] = nil
                if let outcome = outcome {
                    self.finish(drive, outcome, afterWaiting: true)
                } else {
                    self.record("\(drive.name): stopped waiting")
                    self.refreshStatus()
                }
            }
        }
    }

    // MARK: Results

    private func finish(_ drive: Drive, _ outcome: Outcome, afterWaiting: Bool) {
        switch outcome {
        case .ejected(let stopped):
            let detail = stopped.isEmpty ? "" : " Asked to quit: \(stopped.joined(separator: ", "))."
            record("\(drive.name): ejected.\(detail)")
            flash(symbol: "checkmark.circle.fill", text: "Safe to unplug")
            if afterWaiting {
                notify(title: "\(drive.name) is safe to unplug", body: detail.trimmingCharacters(in: .whitespaces))
            }

        case .disconnected:
            record("\(drive.name): no longer connected")
            refreshStatus()

        case .blocked(let names, let stopped):
            record("\(drive.name): in use by \(names.joined(separator: ", "))")
            refreshStatus()
            var message = "In use by: \(names.joined(separator: ", "))"
            if !stopped.isEmpty {
                message += "\nAlready asked to quit: \(stopped.joined(separator: ", "))"
            }
            if afterWaiting {
                showAlert(title: "\(drive.name) is still in use", message: message)
            } else {
                offerToWait(drive, title: "\(drive.name) is still in use", message: message)
            }

        case .failed(let details, let stopped):
            record("\(drive.name): couldn't eject")
            refreshStatus()
            var message = details.isEmpty ? "macOS didn't give a reason." : details
            if !stopped.isEmpty {
                message += "\nAlready asked to quit: \(stopped.joined(separator: ", "))"
            }
            if afterWaiting {
                showAlert(title: "Couldn't eject \(drive.name)", message: message)
            } else {
                offerToWait(drive, title: "Couldn't eject \(drive.name)", message: message)
            }
        }
    }

    private func offerToWait(_ drive: Drive, title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message + "\n\nCast Off can keep checking and eject the drive as soon as it's free."
        alert.addButton(withTitle: "Eject When Free")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            startWatching(drive)
        }
    }

    private func record(_ message: String) {
        activity.insert("\(timeFormatter.string(from: Date()))  \(message)", at: 0)
        activity = Array(activity.prefix(10))
    }

    private func refreshStatus() {
        pendingReset?.cancel()
        pendingReset = nil
        if !ejecting.isEmpty {
            setStatus(symbol: "hourglass", text: "Ejecting…")
        } else if !watches.isEmpty {
            setStatus(symbol: "hourglass", text: "Waiting…")
        } else {
            setStatus(symbol: "eject.fill", text: "")
        }
    }

    private func flash(symbol: String, text: String) {
        pendingReset?.cancel()
        setStatus(symbol: symbol, text: text)
        let reset = DispatchWorkItem { [weak self] in
            self?.refreshStatus()
        }
        pendingReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reset)
    }

    private func setStatus(symbol: String, text: String) {
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Cast Off")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = text.isEmpty ? "" : " \(text)"
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
