import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var networkManager: NetworkManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoSwitch": true])
        networkManager = NetworkManager()
        statusBarController = StatusBarController(networkManager: networkManager)
    }
}
