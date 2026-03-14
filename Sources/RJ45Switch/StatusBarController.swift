import AppKit

final class StatusBarController: NSObject, NetworkManagerDelegate {
    private let statusItem: NSStatusItem
    private let networkManager: NetworkManager
    private var currentState: NetworkState = .disconnected
    private var isSwitching = false
    private var switchAnimationTimer: Timer?
    private var switchAnimationFrame: Int = 0
    private var errorFlashTimer: Timer?
    private var autoSwitchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSwitch") }
        set { UserDefaults.standard.set(newValue, forKey: "autoSwitch") }
    }

    private enum ToggleState: Equatable {
        case wifi
        case ethernet
        case switching
        case disconnected
    }

    private var toggleState: ToggleState = .disconnected

    init(networkManager: NetworkManager) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: 48)
        self.networkManager = networkManager
        super.init()

        networkManager.delegate = self

        // Left click = toggle, right click = context menu
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let state = networkManager.detectState()
        updateUI(with: state)
    }

    // MARK: - NetworkManagerDelegate

    func networkStateDidChange(_ state: NetworkState) {
        let previousState = currentState
        updateUI(with: state)

        guard autoSwitchEnabled, !isSwitching else { return }

        let wasEthernet = previousState.ethernetAvailable
        let isEthernet = state.ethernetAvailable

        if wasEthernet && !isEthernet {
            // Ethernet disappeared (undocked) → switch to WiFi
            isSwitching = true
            setSwitchingState()
            networkManager.switchToWiFi { [weak self] success in
                self?.isSwitching = false
                if !success { self?.flashError() }
            }
        } else if !wasEthernet && isEthernet {
            // Ethernet appeared (docked) → switch to Ethernet
            isSwitching = true
            setSwitchingState()
            networkManager.switchToEthernet { [weak self] success in
                self?.isSwitching = false
                if !success { self?.flashError() }
            }
        }
    }

    // MARK: - Click handling

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            toggle()
        }
    }

    // MARK: - Toggle

    private func toggle() {
        guard !isSwitching else { return }

        switch currentState.activeConnection {
        case .wifi:
            guard currentState.ethernetAvailable else {
                showAlert("Ethernet non disponible.\nVérifiez que le câble RJ45 est branché.")
                return
            }
            isSwitching = true
            setSwitchingState()
            networkManager.switchToEthernet { [weak self] success in
                self?.isSwitching = false
                if !success {
                    self?.flashError()
                    self?.showAlert("Impossible de basculer vers Ethernet.")
                }
            }

        case .ethernet:
            isSwitching = true
            setSwitchingState()
            networkManager.switchToWiFi { [weak self] success in
                self?.isSwitching = false
                if !success {
                    self?.flashError()
                    self?.showAlert("Impossible de basculer vers le WiFi.")
                }
            }

        case .disconnected:
            showContextMenu()
        }
    }

    // MARK: - Context menu (right click)

    private func showContextMenu() {
        let menu = NSMenu()

        // Status header
        let header = NSMenuItem(title: headerText(for: currentState), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let ip = currentState.ipAddress {
            let ipItem = NSMenuItem(title: "IP : \(ip)", action: nil, keyEquivalent: "")
            ipItem.isEnabled = false
            menu.addItem(ipItem)
        }

        if case .wifi(let ssid, let signal) = currentState.activeConnection {
            var detail = ""
            if let ssid = ssid { detail += "SSID : \(ssid)" }
            if let signal = signal { detail += detail.isEmpty ? "\(signal) dBm" : "  (\(signal) dBm)" }
            if !detail.isEmpty {
                let detailItem = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                menu.addItem(detailItem)
            }
        }

        menu.addItem(.separator())

        // Ethernet status
        if currentState.ethernetAvailable {
            let ethItem = NSMenuItem(title: "RJ45 : connecté", action: nil, keyEquivalent: "")
            ethItem.isEnabled = false
            menu.addItem(ethItem)
        } else {
            let ethItem = NSMenuItem(title: "RJ45 : déconnecté", action: nil, keyEquivalent: "")
            ethItem.isEnabled = false
            menu.addItem(ethItem)
        }

        menu.addItem(.separator())

        // Manual switch options
        let wifiItem = NSMenuItem(title: "Passer en WiFi", action: #selector(doSwitchToWiFi), keyEquivalent: "")
        wifiItem.target = self
        if case .wifi = currentState.activeConnection { wifiItem.isEnabled = false }
        menu.addItem(wifiItem)

        let ethSwitchItem = NSMenuItem(title: "Passer en Ethernet", action: #selector(doSwitchToEthernet), keyEquivalent: "")
        ethSwitchItem.target = self
        if case .ethernet = currentState.activeConnection { ethSwitchItem.isEnabled = false }
        if !currentState.ethernetAvailable { ethSwitchItem.isEnabled = false }
        menu.addItem(ethSwitchItem)

        menu.addItem(.separator())

        let autoItem = NSMenuItem(title: "Switch auto (dock/undock)", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = autoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu so left-click action works again
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - UI

    private func updateUI(with state: NetworkState) {
        currentState = state

        guard !isSwitching else { return }

        stopSwitchingAnimation()

        switch state.activeConnection {
        case .wifi:
            toggleState = .wifi
            statusItem.button?.contentTintColor = .systemGreen
        case .ethernet:
            toggleState = .ethernet
            statusItem.button?.contentTintColor = .systemGreen
        case .disconnected:
            toggleState = .disconnected
            statusItem.button?.contentTintColor = nil
        }
        applyToggleImage()
    }

    private func setSwitchingState() {
        toggleState = .switching
        statusItem.button?.contentTintColor = .systemOrange
        applyToggleImage()

        switchAnimationFrame = 0
        switchAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.switchAnimationFrame += 1
            self.applyToggleImage()
        }
    }

    private func stopSwitchingAnimation() {
        switchAnimationTimer?.invalidate()
        switchAnimationTimer = nil
        switchAnimationFrame = 0
    }

    private func applyToggleImage() {
        guard let button = statusItem.button else { return }

        if case .disconnected = toggleState {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            if let image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "Déconnecté")?.withSymbolConfiguration(config) {
                image.isTemplate = true
                button.image = image
            }
            statusItem.length = NSStatusItem.variableLength
            return
        }

        statusItem.length = 48
        button.image = buildToggleImage()
    }

    private func buildToggleImage() -> NSImage {
        let size = NSSize(width: 48, height: 18)
        let image = NSImage(size: size)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        let wifiOpacity: CGFloat
        let cableOpacity: CGFloat

        switch toggleState {
        case .wifi:
            wifiOpacity = 1.0
            cableOpacity = 0.35
        case .ethernet:
            wifiOpacity = 0.35
            cableOpacity = 1.0
        case .switching:
            wifiOpacity = 0.5
            cableOpacity = 0.5
        case .disconnected:
            wifiOpacity = 0.35
            cableOpacity = 0.35
        }

        image.lockFocus()

        // Draw wifi icon at left
        if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let wifiRect = NSRect(x: 0, y: (size.height - wifi.size.height) / 2,
                                  width: wifi.size.width, height: wifi.size.height)
            wifi.draw(in: wifiRect, from: .zero, operation: .sourceOver, fraction: wifiOpacity)
        }

        // Draw dot indicators or switching icon in the center
        let dotY = (size.height - 4) / 2

        let leftDotFilled: Bool
        let rightDotFilled: Bool

        if case .switching = toggleState {
            // Ping-pong: even frames = left filled, odd frames = right filled
            leftDotFilled = (switchAnimationFrame % 2 == 0)
            rightDotFilled = (switchAnimationFrame % 2 != 0)
        } else {
            leftDotFilled = (toggleState == .wifi)
            rightDotFilled = (toggleState == .ethernet)
        }

        // Left dot (wifi side) at x=19
        drawDot(at: NSPoint(x: 19, y: dotY), filled: leftDotFilled)
        // Right dot (cable side) at x=25
        drawDot(at: NSPoint(x: 25, y: dotY), filled: rightDotFilled)

        // Draw cable icon at right
        if let cable = NSImage(systemSymbolName: "cable.connector", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let cableX = size.width - cable.size.width
            let cableRect = NSRect(x: cableX, y: (size.height - cable.size.height) / 2,
                                   width: cable.size.width, height: cable.size.height)
            cable.draw(in: cableRect, from: .zero, operation: .sourceOver, fraction: cableOpacity)
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func drawDot(at point: NSPoint, filled: Bool) {
        let dotSize: CGFloat = 4
        let rect = NSRect(x: point.x, y: point.y, width: dotSize, height: dotSize)
        let path = NSBezierPath(ovalIn: rect)
        if filled {
            NSColor.black.setFill()
            path.fill()
        } else {
            NSColor.black.withAlphaComponent(0.4).setFill()
            path.fill()
        }
    }

    private func headerText(for state: NetworkState) -> String {
        switch state.activeConnection {
        case .wifi:
            return "Connecté via WiFi"
        case .ethernet(let name):
            return "Connecté via \(name)"
        case .disconnected:
            return "Déconnecté"
        }
    }

    // MARK: - Error flash

    private func flashError() {
        errorFlashTimer?.invalidate()
        statusItem.button?.contentTintColor = .systemRed
        errorFlashTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.errorFlashTimer = nil
            self.statusItem.button?.contentTintColor = self.tintColorForCurrentState()
        }
    }

    private func tintColorForCurrentState() -> NSColor? {
        switch currentState.activeConnection {
        case .wifi, .ethernet:
            return .systemGreen
        case .disconnected:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func doSwitchToWiFi() {
        isSwitching = true
        setSwitchingState()
        networkManager.switchToWiFi { [weak self] success in
            self?.isSwitching = false
            if !success {
                self?.flashError()
                self?.showAlert("Impossible de basculer vers le WiFi.")
            }
        }
    }

    @objc private func doSwitchToEthernet() {
        isSwitching = true
        setSwitchingState()
        networkManager.switchToEthernet { [weak self] success in
            self?.isSwitching = false
            if !success {
                self?.flashError()
                self?.showAlert("Impossible de basculer vers Ethernet.")
            }
        }
    }

    @objc private func toggleAutoSwitch() {
        autoSwitchEnabled.toggle()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "RJ45 Switch"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
