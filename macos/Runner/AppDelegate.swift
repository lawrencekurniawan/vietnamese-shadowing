import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    let url = URL(fileURLWithPath: filename)

    guard url.pathExtension.lowercased() == "vshadow" else {
      return false
    }

    MacDocumentOpenBridge.shared.receive(url: url)
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      MacDocumentOpenBridge.shared.receive(url: url)
    }
  }
}
