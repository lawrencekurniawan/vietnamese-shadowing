import AVFoundation
import Flutter
import UIKit
import UniformTypeIdentifiers

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

final class BackupFolderBridge: NSObject, UIDocumentPickerDelegate {
  static let shared = BackupFolderBridge()

  private static let channelName = "vietnamese_shadowing/backup_folder"
  private static let bookmarkKey = "vshadow_backup_folder_bookmark"
  private static let folderNameKey = "vshadow_backup_folder_name"

  private var channel: FlutterMethodChannel?
  private var pendingResult: FlutterResult?
  private var picker: UIDocumentPickerViewController?

  private override init() {
    super.init()
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        return
      }

      switch call.method {
      case "chooseFolder":
        self.chooseFolder(result: result)
      case "getFolder":
        do {
          result(try self.storedFolderInfo())
        } catch {
          result(self.flutterError(error))
        }
      case "clearFolder":
        self.clearStoredFolder()
        result(nil)
      case "writeBackupFile":
        guard
          let arguments = call.arguments as? [String: Any],
          let sourcePath = arguments["sourcePath"] as? String,
          let fileName = arguments["fileName"] as? String
        else {
          result(self.flutterError(
            NSError(
              domain: "VShadowBackupFolder",
              code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "writeBackupFile requires sourcePath and fileName."
              ]
            )
          ))
          return
        }

        do {
          result(try self.writeBackupFile(
            sourcePath: sourcePath,
            fileName: fileName
          ))
        } catch {
          result(self.flutterError(error))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.channel = channel
  }

  private func chooseFolder(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(flutterError(
        NSError(
          domain: "VShadowBackupFolder",
          code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
              "A backup folder picker is already open."
          ]
        )
      ))
      return
    }

    guard let presenter = topViewController() else {
      result(flutterError(
        NSError(
          domain: "VShadowBackupFolder",
          code: 3,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Could not present the backup folder picker."
          ]
        )
      ))
      return
    }

    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder],
      asCopy: false
    )

    picker.delegate = self
    picker.allowsMultipleSelection = false

    pendingResult = result
    self.picker = picker
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let result = pendingResult
    clearPickerState()

    guard let url = urls.first else {
      result?(nil)
      return
    }

    let didAccess = url.startAccessingSecurityScopedResource()

    defer {
      if didAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      try persistBookmark(for: url)
      UserDefaults.standard.set(url.lastPathComponent, forKey: Self.folderNameKey)
      result?([
        "name": url.lastPathComponent,
        "path": url.path
      ])
    } catch {
      result?(flutterError(error))
    }
  }

  func documentPickerWasCancelled(
    _ controller: UIDocumentPickerViewController
  ) {
    let result = pendingResult
    clearPickerState()
    result?(nil)
  }

  private func clearPickerState() {
    picker = nil
    pendingResult = nil
  }

  private func storedFolderInfo() throws -> [String: String]? {
    try withStoredFolder { url in
      let name =
        UserDefaults.standard.string(forKey: Self.folderNameKey) ??
        url.lastPathComponent

      return [
        "name": name,
        "path": url.path
      ]
    }
  }

  private func writeBackupFile(
    sourcePath: String,
    fileName: String
  ) throws -> String {
    try validateFileName(fileName)

    let sourceURL = URL(fileURLWithPath: sourcePath)
    var isDirectory: ObjCBool = false

    guard
      FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw NSError(
        domain: "VShadowBackupFolder",
        code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "The backup file to copy is missing."
        ]
      )
    }

    let resolvedPath = try withStoredFolder { folderURL in
      let destinationURL = folderURL
        .appendingPathComponent(fileName, isDirectory: false)
      let destinationExists = FileManager.default.fileExists(
        atPath: destinationURL.path
      )
      let writingOptions: NSFileCoordinator.WritingOptions =
        destinationExists ? .forReplacing : []

      var coordinationError: NSError?
      var writeError: Error?
      var writtenPath: String?

      NSFileCoordinator().coordinate(
        writingItemAt: destinationURL,
        options: writingOptions,
        error: &coordinationError
      ) { coordinatedURL in
        var temporaryURL: URL?

        do {
          let temporary = coordinatedURL
            .deletingLastPathComponent()
            .appendingPathComponent(
              ".vshadow-\(UUID().uuidString).tmp",
              isDirectory: false
            )

          temporaryURL = temporary

          try FileManager.default.copyItem(at: sourceURL, to: temporary)

          if FileManager.default.fileExists(atPath: coordinatedURL.path) {
            try FileManager.default.removeItem(at: coordinatedURL)
          }

          try FileManager.default.moveItem(at: temporary, to: coordinatedURL)
          writtenPath = coordinatedURL.path
        } catch {
          if let temporaryURL = temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
          }

          writeError = error
        }
      }

      if let coordinationError = coordinationError {
        throw coordinationError
      }

      if let writeError = writeError {
        throw writeError
      }

      guard let writtenPath = writtenPath else {
        throw NSError(
          domain: "VShadowBackupFolder",
          code: 5,
          userInfo: [
            NSLocalizedDescriptionKey: "The backup file was not written."
          ]
        )
      }

      return writtenPath
    }

    guard let resolvedPath = resolvedPath else {
      throw NSError(
        domain: "VShadowBackupFolder",
        code: 7,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Choose an automatic backup folder first."
        ]
      )
    }

    return resolvedPath
  }

  private func withStoredFolder<T>(
    _ body: (URL) throws -> T
  ) throws -> T? {
    guard let storedFolder = try resolveStoredFolder() else {
      return nil
    }

    let folderURL = storedFolder.url
    let didAccess = folderURL.startAccessingSecurityScopedResource()

    defer {
      if didAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    if storedFolder.isStale {
      try? persistBookmark(for: folderURL)
    }

    return try body(folderURL)
  }

  private func resolveStoredFolder() throws -> (url: URL, isStale: Bool)? {
    guard
      let bookmarkData = UserDefaults.standard.data(
        forKey: Self.bookmarkKey
      )
    else {
      return nil
    }

    var isStale = false
    let folderURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    var isDirectory: ObjCBool = false

    guard
      FileManager.default.fileExists(
        atPath: folderURL.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      clearStoredFolder()
      return nil
    }

    return (folderURL, isStale)
  }

  private func persistBookmark(for folderURL: URL) throws {
    let bookmarkData = try folderURL.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
  }

  private func clearStoredFolder() {
    UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    UserDefaults.standard.removeObject(forKey: Self.folderNameKey)
  }

  private func validateFileName(_ fileName: String) throws {
    let invalid =
      fileName.isEmpty ||
      fileName == "." ||
      fileName == ".." ||
      fileName.contains("/") ||
      fileName.contains("\\") ||
      fileName.contains("\u{0}") ||
      fileName.contains(":")

    if invalid {
      throw NSError(
        domain: "VShadowBackupFolder",
        code: 6,
        userInfo: [
          NSLocalizedDescriptionKey: "Unsafe automatic backup filename."
        ]
      )
    }
  }

  private func topViewController() -> UIViewController? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else {
        continue
      }

      let window =
        windowScene.windows.first(where: { $0.isKeyWindow }) ??
        windowScene.windows.first

      guard var controller = window?.rootViewController else {
        continue
      }

      while let presented = controller.presentedViewController {
        controller = presented
      }

      return controller
    }

    return nil
  }

  private func flutterError(_ error: Error) -> FlutterError {
    return FlutterError(
      code: "backup_folder_error",
      message: error.localizedDescription,
      details: nil
    )
  }
}

final class PracticeRecordingBridge {
  static let shared = PracticeRecordingBridge()

  private static let channelName = "vietnamese_shadowing/recording"

  private var channel: FlutterMethodChannel?
  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?

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

      switch call.method {
      case "requestPermission":
        self.requestPermission { granted in
          result(granted)
        }
      case "start":
        self.start(result: result)
      case "stop":
        self.stop(result: result)
      case "cancel":
        self.cancel(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.channel = channel
  }

  private func start(result: @escaping FlutterResult) {
    guard recorder == nil else {
      result(flutterError(
        NSError(
          domain: "VShadowRecording",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "A practice recording is already in progress."
          ]
        )
      ))
      return
    }

    requestPermission { [weak self] granted in
      guard let self = self else {
        return
      }

      guard granted else {
        result(FlutterError(
          code: "microphone_permission_denied",
          message: "Microphone permission is required to record a take.",
          details: nil
        ))
        return
      }

      do {
        let path = try self.beginRecording()
        result([
          "path": path
        ])
      } catch {
        self.deactivateSession()
        result(self.flutterError(error))
      }
    }
  }

  private func beginRecording() throws -> String {
    let session = AVAudioSession.sharedInstance()

    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.defaultToSpeaker, .allowBluetooth]
    )
    try session.setActive(true)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "vshadow-practice-\(UUID().uuidString).wav",
        isDirectory: false
      )

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 44_100.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.prepareToRecord()

    guard recorder.record() else {
      throw NSError(
        domain: "VShadowRecording",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "The recorder did not start."
        ]
      )
    }

    self.recorder = recorder
    self.recordingURL = url

    return url.path
  }

  private func stop(result: @escaping FlutterResult) {
    guard let recorder = recorder else {
      result(nil)
      return
    }

    let duration = recorder.currentTime
    let path = recordingURL?.path

    recorder.stop()
    clearRecording()
    deactivateSession()

    guard let path = path else {
      result(nil)
      return
    }

    result([
      "path": path,
      "duration_seconds": duration
    ])
  }

  private func cancel(result: @escaping FlutterResult) {
    guard let recorder = recorder else {
      result(nil)
      return
    }

    let url = recordingURL

    recorder.stop()
    clearRecording()
    deactivateSession()

    if let url = url {
      try? FileManager.default.removeItem(at: url)
    }

    result(nil)
  }

  private func clearRecording() {
    recorder = nil
    recordingURL = nil
  }

  private func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func requestPermission(completion: @escaping (Bool) -> Void) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { granted in
        DispatchQueue.main.async {
          completion(granted)
        }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          completion(granted)
        }
      }
    }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    return FlutterError(
      code: "recording_error",
      message: error.localizedDescription,
      details: nil
    )
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
    BackupFolderBridge.shared.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    PracticeRecordingBridge.shared.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}
