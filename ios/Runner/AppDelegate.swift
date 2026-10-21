import Flutter
import UIKit

final class DocumentOpenBridge {
  static let shared = DocumentOpenBridge()

  private static let channelName = "vietnamese_shadowing/documents"

  private var channel: FlutterMethodChannel?
  private var pendingPaths: [String] = []
  private var ready = false
  private var lastReceivedPath: String?
  private var lastReceivedAt: Date?

  private init() {}

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        return
      }

      if call.method == "takePendingDocument" {
        self.ready = true
        result(self.pendingPaths.isEmpty ? nil : self.pendingPaths.removeFirst())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    self.channel = channel
  }

  func receive(url: URL) {
    guard url.isFileURL, url.pathExtension.lowercased() == "vshadow" else {
      return
    }

    let now = Date()
    if lastReceivedPath == url.path,
       let previousReceivedAt = lastReceivedAt,
       now.timeIntervalSince(previousReceivedAt) < 1.0 {
      return
    }

    lastReceivedPath = url.path
    lastReceivedAt = now

    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("vshadow-open-\(UUID().uuidString).vshadow")

    do {
      try FileManager.default.copyItem(at: url, to: destination)
      enqueue(destination.path)
    } catch {
      return
    }
  }

  private func enqueue(_ path: String) {
    if ready, let channel = channel {
      channel.invokeMethod("openDocument", arguments: path)
    } else {
      pendingPaths.append(path)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    DocumentOpenBridge.shared.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}
