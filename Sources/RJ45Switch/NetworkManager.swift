import Foundation
import CoreWLAN
import SystemConfiguration

protocol NetworkManagerDelegate: AnyObject {
    func networkStateDidChange(_ state: NetworkState)
}

final class NetworkManager {
    weak var delegate: NetworkManagerDelegate?

    private var dynamicStore: SCDynamicStore?
    private var runLoopSource: CFRunLoopSource?

    init() {
        setupMonitoring()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    // MARK: - Public

    func detectState() -> NetworkState {
        let ethernetInfo = resolveEthernetService()
        let ethernetServiceName = ethernetInfo?.serviceName
        let ethernetInterface = ethernetInfo?.interface
        let ethernetLinkActive = ethernetInterface.map { isInterfaceActive($0) } ?? false
        // Consider ethernet available if the adapter is present (service found),
        // even if the service is currently disabled. switchToEthernet() will enable it.
        let ethernetAdapterPresent = ethernetInfo != nil

        let wifiClient = CWWiFiClient.shared()
        let wifiInterface = wifiClient.interface()
        let wifiPoweredOn = wifiInterface?.powerOn() ?? false
        let wifiIfaceName = wifiInterface?.interfaceName ?? "en0"
        // CoreWLAN SSID requires Location entitlement on recent macOS — fallback to networksetup
        let wifiSSID = wifiInterface?.ssid() ?? ssidViaNetworkSetup(wifiIfaceName)
        let wifiRSSI = wifiInterface.map { Int($0.rssiValue()) }
        let wifiHasIP = getIPAddress(for: wifiIfaceName) != nil

        let defaultIface = defaultInterface()
        let activeConnection: ConnectionType
        let ipAddress: String?

        if let ethIface = ethernetInterface, ethernetLinkActive, defaultIface == ethIface {
            activeConnection = .ethernet(serviceName: ethernetServiceName ?? "Ethernet")
            ipAddress = getIPAddress(for: ethIface)
        } else if wifiPoweredOn, wifiHasIP, defaultIface == wifiIfaceName {
            activeConnection = .wifi(ssid: wifiSSID, signalStrength: wifiRSSI)
            ipAddress = getIPAddress(for: wifiIfaceName)
        } else if let ethIface = ethernetInterface, ethernetLinkActive {
            activeConnection = .ethernet(serviceName: ethernetServiceName ?? "Ethernet")
            ipAddress = getIPAddress(for: ethIface)
        } else if wifiPoweredOn, wifiHasIP {
            activeConnection = .wifi(ssid: wifiSSID, signalStrength: wifiRSSI)
            ipAddress = getIPAddress(for: wifiIfaceName)
        } else {
            activeConnection = .disconnected
            ipAddress = nil
        }

        return NetworkState(
            activeConnection: activeConnection,
            ipAddress: ipAddress,
            wifiAvailable: wifiPoweredOn,
            ethernetAvailable: ethernetAdapterPresent,
            ethernetServiceName: ethernetServiceName,
            ethernetInterface: ethernetInterface
        )
    }

    func switchToEthernet(completion: @escaping (Bool) -> Void) {
        let state = detectState()
        guard let serviceName = state.ethernetServiceName,
              let ethInterface = state.ethernetInterface,
              state.ethernetAvailable else {
            completion(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1. Enable ethernet service
            self?.run("networksetup", "-setnetworkserviceenabled", serviceName, "on")

            // 2. Wait for the interface to get an IP (DHCP can take a few seconds)
            let linkDeadline = Date().addingTimeInterval(10)
            var gotIP = false
            while Date() < linkDeadline {
                if self?.getIPAddress(for: ethInterface) != nil {
                    gotIP = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            guard gotIP else {
                DispatchQueue.main.async {
                    completion(false)
                    if let newState = self?.detectState() {
                        self?.delegate?.networkStateDidChange(newState)
                    }
                }
                return
            }

            // 3. Disable WiFi so ethernet becomes the default route
            if let wifiIface = CWWiFiClient.shared().interface() {
                try? wifiIface.setPower(false)
            }

            // 4. Brief wait for routing table to update
            Thread.sleep(forTimeInterval: 1)

            DispatchQueue.main.async {
                let newState = self?.detectState()
                let success: Bool
                if let s = newState, case .ethernet = s.activeConnection {
                    success = true
                } else {
                    success = gotIP // IP was obtained, consider partial success
                }
                completion(success)
                if let s = newState {
                    self?.delegate?.networkStateDidChange(s)
                }
            }
        }
    }

    func switchToWiFi(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let wifiIface = CWWiFiClient.shared().interface() {
                try? wifiIface.setPower(true)
            }

            if let serviceName = self?.resolveEthernetService()?.serviceName {
                self?.run("networksetup", "-setnetworkserviceenabled", serviceName, "off")
            }

            let deadline = Date().addingTimeInterval(8)
            var success = false
            while Date() < deadline {
                if let newState = self?.detectState(),
                   case .wifi = newState.activeConnection,
                   newState.ipAddress != nil {
                    success = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            DispatchQueue.main.async {
                completion(success)
                if let newState = self?.detectState() {
                    self?.delegate?.networkStateDidChange(newState)
                }
            }
        }
    }

    // MARK: - Network Monitoring

    private func setupMonitoring() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let store = SCDynamicStoreCreate(
            nil,
            "RJ45Switch" as CFString,
            { (_, _, info) in
                guard let info = info else { return }
                let manager = Unmanaged<NetworkManager>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async {
                    let state = manager.detectState()
                    manager.delegate?.networkStateDidChange(state)
                }
            },
            &context
        ) else { return }

        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Interface/.*/Link",
        ] as CFArray

        SCDynamicStoreSetNotificationKeys(store, nil, keys)

        if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.runLoopSource = source
        }
        self.dynamicStore = store
    }

    // MARK: - Helpers

    private func resolveEthernetService() -> (serviceName: String, interface: String)? {
        let output = run("networksetup", "-listallhardwareports")
        let blocks = output.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            var port: String?
            var device: String?
            for line in lines {
                if line.hasPrefix("Hardware Port: ") {
                    port = String(line.dropFirst("Hardware Port: ".count))
                } else if line.hasPrefix("Device: ") {
                    device = String(line.dropFirst("Device: ".count))
                }
            }
            if let port = port, let device = device {
                let lower = port.lowercased()
                if lower.contains("usb") && (lower.contains("lan") || lower.contains("ethernet")) {
                    return (serviceName: port, interface: device)
                }
            }
        }
        return nil
    }

    private func ssidViaNetworkSetup(_ iface: String) -> String? {
        let output = run("networksetup", "-getairportnetwork", iface)
        // Output: "Current Wi-Fi Network: MyNetwork"
        guard let range = output.range(of: "Current Wi-Fi Network: ") else { return nil }
        let ssid = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }

    private func defaultInterface() -> String? {
        let output = run("route", "-n", "get", "default")
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func isInterfaceActive(_ iface: String) -> Bool {
        let output = run("ifconfig", iface)
        return output.contains("status: active")
    }

    private func getIPAddress(for iface: String) -> String? {
        let output = run("ifconfig", iface)
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("inet ") {
                let parts = trimmed.components(separatedBy: " ")
                if parts.count >= 2 {
                    return parts[1]
                }
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ command: String, _ arguments: String...) -> String {
        let process = Process()
        let pipe = Pipe()

        let paths = ["/usr/sbin/", "/sbin/", "/usr/bin/", "/bin/"]
        process.executableURL = URL(fileURLWithPath: "/usr/bin/\(command)")
        for path in paths {
            let url = URL(fileURLWithPath: "\(path)\(command)")
            if FileManager.default.fileExists(atPath: url.path) {
                process.executableURL = url
                break
            }
        }

        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
