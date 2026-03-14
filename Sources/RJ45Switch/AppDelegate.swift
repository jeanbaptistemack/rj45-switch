import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!
    private var networkManager: NetworkManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        networkManager = NetworkManager()
        statusBarController = StatusBarController(networkManager: networkManager)
    }
}
