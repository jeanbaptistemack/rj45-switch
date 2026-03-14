import Foundation

enum ConnectionType: Equatable {
    case wifi(ssid: String?, signalStrength: Int?)
    case ethernet(serviceName: String)
    case disconnected
}

struct NetworkState {
    let activeConnection: ConnectionType
    let ipAddress: String?
    let wifiAvailable: Bool
    let ethernetAvailable: Bool
    let ethernetServiceName: String?
    let ethernetInterface: String?

    static let disconnected = NetworkState(
        activeConnection: .disconnected,
        ipAddress: nil,
        wifiAvailable: false,
        ethernetAvailable: false,
        ethernetServiceName: nil,
        ethernetInterface: nil
    )
}
