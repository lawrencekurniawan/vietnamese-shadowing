import AVFoundation
import Flutter
import Speech
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

final class PracticeAssessmentBridge {
  static let shared = PracticeAssessmentBridge()

  private static let channelName = "vietnamese_shadowing/practice_assessment"

  private var channel: FlutterMethodChannel?
  private var activeRecognizer: SFSpeechRecognizer?
  private var activeTask: SFSpeechRecognitionTask?
  private var recognitionGeneration = 0

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

      let arguments = call.arguments as? [String: Any] ?? [:]

      switch call.method {
      case "transcribe":
        self.transcribe(arguments: arguments, result: result)
      case "pitch":
        self.pitch(arguments: arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.channel = channel
  }

  private func transcribe(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(FlutterError(
        code: "invalid_audio",
        message: "The recording path is missing.",
        details: nil
      ))
      return
    }

    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(
        code: "invalid_audio",
        message: "The recording file no longer exists.",
        details: nil
      ))
      return
    }

    let localeIdentifier = arguments["locale"] as? String ?? "vi-VN"

    recognitionGeneration += 1
    let generation = recognitionGeneration

    activeTask?.cancel()
    activeTask = nil
    activeRecognizer = nil

    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard generation == self.recognitionGeneration else {
          result(FlutterError(
            code: "recognition_cancelled",
            message: "Speech recognition was superseded by a newer request.",
            details: nil
          ))
          return
        }

        guard status == .authorized else {
          result(FlutterError(
            code: "speech_permission_denied",
            message: status == .restricted
              ? "Speech recognition is restricted on this device."
              : "Speech recognition permission is required for feedback. "
                + "Enable it in iOS Settings.",
            details: nil
          ))
          return
        }

        guard let recognizer = SFSpeechRecognizer(
          locale: Locale(identifier: localeIdentifier)
        ) else {
          result(FlutterError(
            code: "speech_unavailable",
            message: "Vietnamese speech recognition is not available.",
            details: nil
          ))
          return
        }

        guard recognizer.isAvailable else {
          result(FlutterError(
            code: "speech_unavailable",
            message: "Vietnamese speech recognition is temporarily unavailable.",
            details: nil
          ))
          return
        }

        guard recognizer.supportsOnDeviceRecognition else {
          result(FlutterError(
            code: "on_device_recognition_unavailable",
            message: "On-device Vietnamese speech recognition is not available "
              + "on this device. Feedback is unavailable without sending audio "
              + "to a server.",
            details: nil
          ))
          return
        }

        let request = SFSpeechURLRecognitionRequest(
          url: URL(fileURLWithPath: path)
        )
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = true

        if #available(iOS 16.0, *) {
          request.addsPunctuation = true
        }

        var completed = false

        let finish: (Any?) -> Void = { [weak self] value in
          guard !completed else {
            return
          }

          completed = true

          if self?.recognitionGeneration == generation {
            self?.activeTask = nil
            self?.activeRecognizer = nil
          }

          result(value)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
          guard
            !completed,
            let self = self,
            generation == self.recognitionGeneration
          else {
            return
          }

          self.activeTask?.cancel()
          finish(FlutterError(
            code: "recognition_timeout",
            message: "Speech recognition took too long. Try a shorter take.",
            details: nil
          ))
        }

        self.activeRecognizer = recognizer
        let task = recognizer.recognitionTask(with: request) { recognitionResult, error in
          DispatchQueue.main.async {
            if let error = error {
              finish(FlutterError(
                code: "recognition_failed",
                message: error.localizedDescription,
                details: nil
              ))
              return
            }

            guard
              let recognitionResult = recognitionResult,
              recognitionResult.isFinal
            else {
              return
            }

            let segments: [[String: Any]] = recognitionResult
              .bestTranscription
              .segments
              .map { segment in
                [
                  "text": segment.substring,
                  "start_seconds": segment.timestamp,
                  "duration_seconds": segment.duration,
                  "confidence": segment.confidence >= 0
                    ? Double(segment.confidence)
                    : NSNull()
                ]
              }

            finish([
              "text": recognitionResult.bestTranscription.formattedString,
              "segments": segments,
              "on_device": true
            ])
          }
        }
        self.activeTask = task
      }
    }
  }

  private func pitch(
    arguments: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(FlutterError(
        code: "invalid_audio",
        message: "The recording path is missing.",
        details: nil
      ))
      return
    }

    guard FileManager.default.fileExists(atPath: path) else {
      result(FlutterError(
        code: "invalid_audio",
        message: "The recording file no longer exists.",
        details: nil
      ))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let frames = try Self.extractPitchFrames(path: path)
        DispatchQueue.main.async {
          result(["frames": frames])
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "pitch_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private static func extractPitchFrames(
    path: String
  ) throws -> [[String: Any]] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let bytes = [UInt8](data)
    let wav = try parseWav(bytes)
    let targetRate = 8_000.0
    let maximumSourceSeconds = 90.0
    let sourceFrames = min(
      wav.frameCount,
      Int(wav.sampleRate * maximumSourceSeconds)
    )

    guard sourceFrames > 0 else {
      return []
    }

    var mono = [Double]()
    mono.reserveCapacity(sourceFrames)

    for frame in 0..<sourceFrames {
      var sum = 0.0

      for channel in 0..<wav.channels {
        let sampleOffset =
          wav.dataOffset + frame * wav.blockAlign + channel * wav.bytesPerSample
        sum += readSample(
          bytes: bytes,
          offset: sampleOffset,
          bitsPerSample: wav.bitsPerSample
        )
      }

      mono.append(sum / Double(wav.channels))
    }

    let targetCount = Int(
      Double(sourceFrames) * targetRate / wav.sampleRate
    )

    guard targetCount >= 320 else {
      return []
    }

    var samples = [Double](repeating: 0, count: targetCount)

    for index in 0..<targetCount {
      let position = Double(index) * wav.sampleRate / targetRate
      let base = Int(position)
      let fraction = position - Double(base)
      let next = min(base + 1, sourceFrames - 1)
      samples[index] =
        mono[base] * (1.0 - fraction) + mono[next] * fraction
    }

    let window = 320
    let hop = 80
    let minimumLag = 19
    let maximumLag = min(114, window - 2)
    var frames: [[String: Any]] = []
    var work = [Double](repeating: 0, count: window)

    guard samples.count >= window else {
      return []
    }

    for start in stride(
      from: 0,
      through: samples.count - window,
      by: hop
    ) {
      var mean = 0.0

      for index in 0..<window {
        mean += samples[start + index]
      }

      mean /= Double(window)

      var energy = 0.0

      for index in 0..<window {
        let value = samples[start + index] - mean
        work[index] = value
        energy += value * value
      }

      let rms = sqrt(energy / Double(window))

      if rms < 0.008 {
        continue
      }

      var bestLag = 0
      var bestCorrelation = -1.0

      for lag in minimumLag...maximumLag {
        var dot = 0.0
        var energyA = 0.0
        var energyB = 0.0
        let limit = window - lag

        for index in 0..<limit {
          let a = work[index]
          let b = work[index + lag]
          dot += a * b
          energyA += a * a
          energyB += b * b
        }

        let denominator = sqrt(energyA * energyB) + 1e-12
        let correlation = dot / denominator

        if correlation > bestCorrelation {
          bestCorrelation = correlation
          bestLag = lag
        }
      }

      guard bestLag > 0 && bestCorrelation >= 0.28 else {
        continue
      }

      let frequency = targetRate / Double(bestLag)

      guard frequency >= 70.0 && frequency <= 420.0 else {
        continue
      }

      frames.append([
        "time_seconds": Double(start + window / 2) / targetRate,
        "f0_hz": frequency
      ])
    }

    return frames
  }

  private struct WavData {
    let sampleRate: Double
    let channels: Int
    let bitsPerSample: Int
    let blockAlign: Int
    let bytesPerSample: Int
    let dataOffset: Int
    let dataSize: Int

    var frameCount: Int {
      guard blockAlign > 0 else {
        return 0
      }

      return dataSize / blockAlign
    }
  }

  private static func parseWav(_ bytes: [UInt8]) throws -> WavData {
    guard bytes.count >= 44 else {
      throw NSError(
        domain: "VShadowPitch",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "The WAV file is too small."
        ]
      )
    }

    guard
      String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
      String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw NSError(
        domain: "VShadowPitch",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "The file is not a PCM WAV recording."
        ]
      )
    }

    var offset = 12
    var audioFormat: Int?
    var channels: Int?
    var sampleRate: Double?
    var blockAlign: Int?
    var bitsPerSample: Int?
    var dataOffset: Int?
    var dataSize: Int?

    while offset + 8 <= bytes.count {
      let chunkId = String(
        bytes: bytes[offset..<(offset + 4)],
        encoding: .ascii
      ) ?? ""
      let chunkSize = Int(readUInt32(bytes, offset + 4))
      let chunkDataStart = offset + 8

      guard chunkSize <= bytes.count - chunkDataStart else {
        throw NSError(
          domain: "VShadowPitch",
          code: 3,
          userInfo: [
            NSLocalizedDescriptionKey: "A WAV chunk exceeds the file size."
          ]
        )
      }

      if chunkId == "fmt " {
        guard chunkSize >= 16 else {
          throw NSError(
            domain: "VShadowPitch",
            code: 4,
            userInfo: [
              NSLocalizedDescriptionKey: "The WAV format chunk is invalid."
            ]
          )
        }

        audioFormat = Int(readUInt16(bytes, chunkDataStart))
        channels = Int(readUInt16(bytes, chunkDataStart + 2))
        sampleRate = Double(readUInt32(bytes, chunkDataStart + 4))
        blockAlign = Int(readUInt16(bytes, chunkDataStart + 12))
        bitsPerSample = Int(readUInt16(bytes, chunkDataStart + 14))
      } else if chunkId == "data" {
        dataOffset = chunkDataStart
        dataSize = chunkSize
        break
      }

      offset = chunkDataStart + chunkSize

      if offset % 2 == 1 {
        offset += 1
      }
    }

    guard
      audioFormat == 1,
      let channels = channels,
      channels > 0,
      let sampleRate = sampleRate,
      sampleRate >= 8_000,
      let blockAlign = blockAlign,
      blockAlign > 0,
      let bitsPerSample = bitsPerSample,
      [8, 16, 24, 32].contains(bitsPerSample),
      let dataOffset = dataOffset,
      let dataSize = dataSize,
      dataSize > 0
    else {
      throw NSError(
        domain: "VShadowPitch",
        code: 5,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The recording is not a supported 8/16/24/32-bit PCM WAV file."
        ]
      )
    }

    let bytesPerSample = bitsPerSample / 8

    guard blockAlign == channels * bytesPerSample else {
      throw NSError(
        domain: "VShadowPitch",
        code: 6,
        userInfo: [
          NSLocalizedDescriptionKey: "The WAV block alignment is invalid."
        ]
      )
    }

    return WavData(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      blockAlign: blockAlign,
      bytesPerSample: bytesPerSample,
      dataOffset: dataOffset,
      dataSize: dataSize
    )
  }

  private static func readSample(
    bytes: [UInt8],
    offset: Int,
    bitsPerSample: Int
  ) -> Double {
    switch bitsPerSample {
    case 8:
      return (Double(Int(bytes[offset]) - 128)) / 128.0
    case 16:
      let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
      return Double(Int16(bitPattern: raw)) / 32_768.0
    case 24:
      var value =
        Int(bytes[offset]) |
        (Int(bytes[offset + 1]) << 8) |
        (Int(bytes[offset + 2]) << 16)

      if value & 0x0080_0000 != 0 {
        value -= 0x0100_0000
      }

      return Double(value) / 8_388_608.0
    case 32:
      let raw =
        UInt32(bytes[offset]) |
        (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) |
        (UInt32(bytes[offset + 3]) << 24)
      return Double(Int32(bitPattern: raw)) / 2_147_483_648.0
    default:
      return 0
    }
  }

  private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    return UInt32(bytes[offset]) |
      (UInt32(bytes[offset + 1]) << 8) |
      (UInt32(bytes[offset + 2]) << 16) |
      (UInt32(bytes[offset + 3]) << 24)
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
    PracticeAssessmentBridge.shared.register(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }
}
