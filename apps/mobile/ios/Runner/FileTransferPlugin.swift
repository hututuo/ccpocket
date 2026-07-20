import Darwin
import Flutter
import UIKit
import UniformTypeIdentifiers

enum FileTransferNativeError: Error, Equatable {
  case invalidPath
  case outsideSandbox
  case notRegularFile
  case symlinkRejected
  case sizeOutOfRange
  case crossVolume
  case identityMismatch
  case collision
  case missingFile
  case insufficientStorage
}

private enum FileTransferPickerMode {
  case importing
  case exporting
}

final class FileTransferPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static let channelName = "ccpocket/file_transfer"
  static let nativeAPIVersion = 2
  static let minimumOSMajorVersion = 15
  static let maximumBytes: Int64 = 15 * 1024 * 1024 * 1024
  static let capacitySafetyMarginBytes: Int64 = 512 * 1024 * 1024

  private var pickerResult: FlutterResult?
  private var pickerMaximumBytes: Int64 = maximumBytes
  private var pickerMode: FileTransferPickerMode?
  private weak var pickerController: UIDocumentPickerViewController?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FileTransferPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSupportInfo":
      result(
        Self.supportInfo(
          osVersion: ProcessInfo.processInfo.operatingSystemVersion,
          appVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
          ) as? String,
          buildNumber: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
          ) as? String
        )
      )
    case "pickFile":
      DispatchQueue.main.async { [weak self] in
        self?.presentPicker(arguments: call.arguments, result: result)
      }
    case "exportFile":
      DispatchQueue.main.async { [weak self] in
        self?.presentExportPicker(arguments: call.arguments, result: result)
      }
    case "availableCapacity":
      perform(arguments: call.arguments, result: result) { arguments in
        let url = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "path"),
          mustExist: true
        )
        return try Self.availableCapacity(at: url)
      }
    case "markTransient":
      perform(arguments: call.arguments, result: result) { arguments in
        let url = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "path"),
          mustExist: true
        )
        try Self.markTransient(url)
        return nil
      }
    case "chooseFinalFilename":
      perform(arguments: call.arguments, result: result) { arguments in
        let directory = try Self.validatedDirectory(
          path: try Self.string(arguments, "directoryPath")
        )
        return try Self.chooseFinalFilename(
          directory: directory,
          requested: try Self.string(arguments, "requestedFilename")
        )
      }
    case "probeCommit":
      perform(arguments: call.arguments, result: result) { arguments in
        let partial = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "partialPath"),
          mustExist: false
        )
        let final = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "finalPath"),
          mustExist: false
        )
        let expected = arguments["expectedResourceIdentifier"] as? String
        return try Self.probeCommit(
          partial: partial,
          final: final,
          expectedIdentifier: expected
        )
      }
    case "linkNoClobber":
      perform(arguments: call.arguments, result: result) { arguments in
        let partial = try Self.validatedRegularFile(
          path: try Self.string(arguments, "partialPath")
        )
        let final = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "finalPath"),
          mustExist: false
        )
        return try Self.linkNoClobber(partial: partial, final: final)
      }
    case "finalizeLinkedCommit":
      perform(arguments: call.arguments, result: result) { arguments in
        let partial = try Self.validatedSandboxURL(
          path: try Self.string(arguments, "partialPath"),
          mustExist: false
        )
        let final = try Self.validatedRegularFile(
          path: try Self.string(arguments, "finalPath")
        )
        try Self.finalizeLinkedCommit(
          partial: partial,
          final: final,
          expectedIdentifier: try Self.string(
            arguments,
            "expectedResourceIdentifier"
          )
        )
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func supportInfo(
    osVersion: OperatingSystemVersion,
    appVersion: String? = nil,
    buildNumber: String? = nil
  ) -> [String: Any] {
    var value: [String: Any] = [
      "supported": osVersion.majorVersion >= minimumOSMajorVersion,
      "iosMajor": osVersion.majorVersion,
      "iosMinor": osVersion.minorVersion,
      "iosPatch": osVersion.patchVersion,
      "nativeApiVersion": nativeAPIVersion,
    ]
    if let appVersion { value["appVersion"] = appVersion }
    if let buildNumber { value["buildNumber"] = buildNumber }
    return value
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    if pickerMode == .exporting {
      finishPicker(!urls.isEmpty)
      return
    }
    guard let url = urls.first else {
      finishPicker(nil)
      return
    }
    let maximumBytes = pickerMaximumBytes
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let value = try Self.copyPickedFile(url, maximumBytes: maximumBytes)
        DispatchQueue.main.async { self?.finishPicker(value) }
      } catch {
        DispatchQueue.main.async {
          self?.finishPicker(Self.flutterError(error))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finishPicker(nil)
  }

  private func presentPicker(arguments: Any?, result: @escaping FlutterResult) {
    guard pickerResult == nil else {
      result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
      return
    }
    guard let arguments = arguments as? [String: Any],
      let rawMaximum = arguments["maxSizeBytes"] as? NSNumber
    else {
      result(FlutterError(code: "invalid_args", message: "Missing maxSizeBytes", details: nil))
      return
    }
    let maximum = rawMaximum.int64Value
    guard maximum > 0, maximum <= Self.maximumBytes else {
      result(FlutterError(code: "size_out_of_range", message: "Invalid size limit", details: nil))
      return
    }
    guard let presenter = Self.activePresenter() else {
      result(FlutterError(code: "no_presenter", message: "No active window", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.item],
      asCopy: false
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.modalPresentationStyle = .formSheet
    pickerResult = result
    pickerMaximumBytes = maximum
    pickerMode = .importing
    pickerController = picker
    presenter.present(picker, animated: true)
  }

  private func presentExportPicker(arguments: Any?, result: @escaping FlutterResult) {
    guard pickerResult == nil else {
      result(FlutterError(code: "busy", message: "A picker is already open", details: nil))
      return
    }
    guard let arguments = arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(FlutterError(code: "invalid_args", message: "Missing path", details: nil))
      return
    }
    let fileURL: URL
    do {
      fileURL = try Self.validatedRegularFile(path: path)
    } catch {
      result(Self.flutterError(error))
      return
    }
    guard let presenter = Self.activePresenter() else {
      result(FlutterError(code: "no_presenter", message: "No active window", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(
      forExporting: [fileURL],
      asCopy: true
    )
    picker.delegate = self
    picker.modalPresentationStyle = .formSheet
    pickerResult = result
    pickerMode = .exporting
    pickerController = picker
    presenter.present(picker, animated: true)
  }

  private func finishPicker(_ value: Any?) {
    guard let result = pickerResult else { return }
    pickerResult = nil
    pickerMode = nil
    pickerController = nil
    result(value)
  }

  private func perform(
    arguments: Any?,
    result: @escaping FlutterResult,
    operation: @escaping ([String: Any]) throws -> Any?
  ) {
    guard let arguments = arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_args", message: "Missing arguments", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try operation(arguments)
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async { result(Self.flutterError(error)) }
      }
    }
  }

  static func copyPickedFile(
    _ source: URL,
    maximumBytes: Int64,
    stagingRootURL: URL? = nil,
    fileManager: FileManager = .default
  ) throws -> [String: Any] {
    guard maximumBytes > 0, maximumBytes <= Self.maximumBytes else {
      throw FileTransferNativeError.sizeOutOfRange
    }
    let accessing = source.startAccessingSecurityScopedResource()
    defer { if accessing { source.stopAccessingSecurityScopedResource() } }
    var rawSourceStat = stat()
    if Darwin.lstat(source.path, &rawSourceStat) == 0,
      (rawSourceStat.st_mode & S_IFMT) == S_IFLNK
    {
      throw FileTransferNativeError.symlinkRejected
    }
    var coordinatedResult: [String: Any]?
    var operationError: Error?
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: source,
      options: .withoutChanges,
      error: &coordinationError
    ) { coordinatedSource in
      do {
        coordinatedResult = try copyCoordinatedPickedFile(
          coordinatedSource,
          displayName: source.lastPathComponent,
          maximumBytes: maximumBytes,
          stagingRootURL: stagingRootURL,
          fileManager: fileManager
        )
      } catch {
        operationError = error
      }
    }
    if let operationError { throw operationError }
    if let coordinationError { throw coordinationError }
    guard let coordinatedResult else {
      throw FileTransferNativeError.missingFile
    }
    return coordinatedResult
  }

  private static func copyCoordinatedPickedFile(
    _ source: URL,
    displayName: String,
    maximumBytes: Int64,
    stagingRootURL: URL?,
    fileManager: FileManager
  ) throws -> [String: Any] {
    let sourceValues = try source.resourceValues(forKeys: [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
    ])
    guard sourceValues.isSymbolicLink != true else {
      throw FileTransferNativeError.symlinkRejected
    }
    guard sourceValues.isRegularFile == true else {
      throw FileTransferNativeError.notRegularFile
    }
    var sourcePathStat = stat()
    guard Darwin.lstat(source.path, &sourcePathStat) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard (sourcePathStat.st_mode & S_IFMT) != S_IFLNK else {
      throw FileTransferNativeError.symlinkRejected
    }

    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let before = try descriptorStat(input.fileDescriptor)
    guard (before.st_mode & S_IFMT) == S_IFREG else {
      throw FileTransferNativeError.notRegularFile
    }
    let declaredSize = Int64(before.st_size)
    guard declaredSize >= 0, declaredSize <= maximumBytes else {
      throw FileTransferNativeError.sizeOutOfRange
    }
    if let resourceSize = sourceValues.fileSize,
      Int64(resourceSize) != declaredSize
    {
      throw FileTransferNativeError.identityMismatch
    }

    let pickerRoot: URL
    if let stagingRootURL {
      pickerRoot = stagingRootURL
      try fileManager.createDirectory(
        at: pickerRoot,
        withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
      )
      try markTransient(pickerRoot)
    } else {
      pickerRoot = try pickerStagingRoot(fileManager: fileManager)
    }
    guard let available = try availableCapacity(at: pickerRoot),
      available >= declaredSize + capacitySafetyMarginBytes
    else {
      throw FileTransferNativeError.insufficientStorage
    }

    let staging = pickerRoot.appendingPathComponent(
      "ccpocket-picker-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(
      at: staging,
      withIntermediateDirectories: false,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    try markTransient(staging)
    let temporary = staging.appendingPathComponent("copy.tmp")
    let final = staging.appendingPathComponent("picked.stage")
    guard fileManager.createFile(
      atPath: temporary.path,
      contents: nil,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let output = try FileHandle(forWritingTo: temporary)
      defer { try? output.close() }
      var copied: Int64 = 0
      while true {
        let data = try autoreleasepool {
          try input.read(upToCount: 1024 * 1024)
        }
        guard let data, !data.isEmpty else { break }
        copied += Int64(data.count)
        guard copied <= maximumBytes else {
          throw FileTransferNativeError.sizeOutOfRange
        }
        guard copied <= declaredSize else {
          throw FileTransferNativeError.identityMismatch
        }
        try output.write(contentsOf: data)
      }
      let after = try descriptorStat(input.fileDescriptor)
      guard copied == declaredSize, sameSourceIdentity(before, after) else {
        throw FileTransferNativeError.identityMismatch
      }
      try output.synchronize()
      try output.close()
      try fileManager.moveItem(at: temporary, to: final)
      try markTransient(final)
      try syncDirectory(staging)
      return [
        "path": final.path,
        "filename": sanitizedFilename(displayName),
        "sizeBytes": copied,
      ]
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  static func pickerStagingRoot(
    fileManager: FileManager = .default
  ) throws -> URL {
    let support = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = support
      .appendingPathComponent("CCPocketFileTransfers", isDirectory: true)
      .appendingPathComponent("v2", isDirectory: true)
      .appendingPathComponent("picker", isDirectory: true)
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    )
    try markTransient(root)
    return root
  }

  static func availableCapacity(at url: URL) throws -> Int64? {
    let values = try url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    if let capacity = values.volumeAvailableCapacityForImportantUsage {
      return capacity
    }
    return values.volumeAvailableCapacity.map(Int64.init)
  }

  static func markTransient(_ url: URL) throws {
    var mutable = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutable.setResourceValues(values)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: url.path
    )
  }

  static func chooseFinalFilename(
    directory: URL,
    requested: String,
    fileManager: FileManager = .default
  ) throws -> String {
    let safe = sanitizedFilename(requested)
    let ns = safe as NSString
    let ext = ns.pathExtension
    let stem = ns.deletingPathExtension.isEmpty ? safe : ns.deletingPathExtension
    for suffix in 0..<10_000 {
      let name: String
      if suffix == 0 {
        name = safe
      } else {
        let suffixText = " (\(suffix))"
        let extensionText = ext.isEmpty ? "" : ".\(ext)"
        let budget = 240 - suffixText.utf8.count - extensionText.utf8.count
        name = "\(truncateUtf8(stem, maximumBytes: max(1, budget)))\(suffixText)\(extensionText)"
      }
      let candidate = directory.appendingPathComponent(name, isDirectory: false)
      if lstatExists(candidate.path) == false { return name }
    }
    throw FileTransferNativeError.collision
  }

  static func probeCommit(
    partial: URL,
    final: URL,
    expectedIdentifier: String?
  ) throws -> [String: Any] {
    let partialInfo = try optionalRegularIdentity(partial)
    let finalInfo = try optionalRegularIdentity(final)
    switch (partialInfo, finalInfo) {
    case let (.some(partialId), .some(finalId)):
      guard partialId == finalId else { return ["state": "collision"] }
      if let expectedIdentifier, expectedIdentifier != finalId {
        throw FileTransferNativeError.identityMismatch
      }
      try restoreCompletedBackupSemantics(final)
      return ["state": "linked", "resourceIdentifier": finalId]
    case (.some, .none):
      guard expectedIdentifier == nil else {
        throw FileTransferNativeError.identityMismatch
      }
      return ["state": "ready"]
    case let (.none, .some(finalId)):
      guard expectedIdentifier == finalId else { return ["state": "collision"] }
      try restoreCompletedBackupSemantics(final)
      return ["state": "complete", "resourceIdentifier": finalId]
    case (.none, .none):
      throw FileTransferNativeError.missingFile
    }
  }

  static func linkNoClobber(partial: URL, final: URL) throws -> String {
    guard !lstatExists(final.path) else { throw FileTransferNativeError.collision }
    let parent = try validatedDirectory(path: final.deletingLastPathComponent().path)
    let sourceStat = try statInfo(partial, followLinks: false)
    let parentStat = try statInfo(parent, followLinks: true)
    guard sourceStat.st_dev == parentStat.st_dev else {
      throw FileTransferNativeError.crossVolume
    }
    guard Darwin.link(partial.path, final.path) == 0 else {
      if errno == EEXIST { throw FileTransferNativeError.collision }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try restoreCompletedBackupSemantics(final)
    try syncDirectory(final.deletingLastPathComponent())
    return try regularIdentity(final)
  }

  static func finalizeLinkedCommit(
    partial: URL,
    final: URL,
    expectedIdentifier: String
  ) throws {
    let finalId = try regularIdentity(final)
    guard finalId == expectedIdentifier else {
      throw FileTransferNativeError.identityMismatch
    }
    try restoreCompletedBackupSemantics(final)
    if let partialId = try optionalRegularIdentity(partial) {
      guard partialId == expectedIdentifier else {
        throw FileTransferNativeError.identityMismatch
      }
      guard Darwin.unlink(partial.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try syncDirectory(partial.deletingLastPathComponent())
    }
    try syncDirectory(final.deletingLastPathComponent())
  }

  static func validatedRegularFile(path: String) throws -> URL {
    let url = try validatedSandboxURL(path: path, mustExist: true)
    let info = try statInfo(url, followLinks: false)
    guard (info.st_mode & S_IFMT) != S_IFLNK else {
      throw FileTransferNativeError.symlinkRejected
    }
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw FileTransferNativeError.notRegularFile
    }
    return url
  }

  static func validatedDirectory(path: String) throws -> URL {
    let url = try validatedSandboxURL(path: path, mustExist: true)
    let info = try statInfo(url, followLinks: false)
    guard (info.st_mode & S_IFMT) != S_IFLNK else {
      throw FileTransferNativeError.symlinkRejected
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR else {
      throw FileTransferNativeError.invalidPath
    }
    return url
  }

  static func validatedSandboxURL(
    path: String,
    homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    mustExist: Bool
  ) throws -> URL {
    guard !path.isEmpty,
      !path.unicodeScalars.contains(where: { $0.value == 0 }),
      (path as NSString).isAbsolutePath
    else { throw FileTransferNativeError.invalidPath }
    let raw = URL(fileURLWithPath: path).standardizedFileURL
    var rawLeafStat = stat()
    let leafResult = Darwin.lstat(raw.path, &rawLeafStat)
    if leafResult == 0, (rawLeafStat.st_mode & S_IFMT) == S_IFLNK {
      throw FileTransferNativeError.symlinkRejected
    }
    if leafResult != 0, errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if mustExist, leafResult != 0 {
      throw FileTransferNativeError.missingFile
    }
    let home = homeDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = raw.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(raw.lastPathComponent)
    guard candidate.pathComponents.count > home.pathComponents.count,
      Array(candidate.pathComponents.prefix(home.pathComponents.count)) == home.pathComponents
    else { throw FileTransferNativeError.outsideSandbox }
    return candidate
  }

  static func sanitizedFilename(_ value: String) -> String {
    let normalized = value.precomposedStringWithCanonicalMapping
    let forbidden = CharacterSet.controlCharacters.union(
      CharacterSet(charactersIn: "/\\")
    )
    let scalars = normalized.unicodeScalars.map { scalar -> String in
      forbidden.contains(scalar) ? "_" : String(scalar)
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    let safe = scalars.isEmpty || scalars == "." || scalars == ".." ? "file" : scalars
    return truncateUtf8(safe, maximumBytes: 240)
  }

  static func truncateUtf8(_ value: String, maximumBytes: Int) -> String {
    var output = ""
    var used = 0
    for character in value {
      let bytes = String(character).utf8.count
      if used + bytes > maximumBytes { break }
      output.append(character)
      used += bytes
    }
    return output.isEmpty ? "file" : output
  }

  static func regularIdentity(_ url: URL) throws -> String {
    let info = try statInfo(url, followLinks: false)
    guard (info.st_mode & S_IFMT) == S_IFREG else {
      throw FileTransferNativeError.notRegularFile
    }
    return "\(UInt64(info.st_dev)):\(UInt64(info.st_ino))"
  }

  static func optionalRegularIdentity(_ url: URL) throws -> String? {
    guard lstatExists(url.path) else { return nil }
    return try regularIdentity(url)
  }

  static func statInfo(_ url: URL, followLinks: Bool) throws -> stat {
    var info = stat()
    let flags: Int32 = followLinks ? 0 : AT_SYMLINK_NOFOLLOW
    let result = Darwin.fstatat(AT_FDCWD, url.path, &info, flags)
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info
  }

  static func descriptorStat(_ descriptor: Int32) throws -> stat {
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info
  }

  static func sameSourceIdentity(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev &&
      left.st_ino == right.st_ino &&
      left.st_size == right.st_size &&
      left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
      left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec &&
      left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec &&
      left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
  }

  static func lstatExists(_ path: String) -> Bool {
    var info = stat()
    return Darwin.lstat(path, &info) == 0
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  static func restoreCompletedBackupSemantics(_ url: URL) throws {
    var mutable = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = false
    try mutable.setResourceValues(values)
  }

  static func string(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
      throw FileTransferNativeError.invalidPath
    }
    return value
  }

  static func flutterError(_ error: Error) -> FlutterError {
    let code: String
    switch error {
    case FileTransferNativeError.invalidPath: code = "invalid_path"
    case FileTransferNativeError.outsideSandbox: code = "outside_sandbox"
    case FileTransferNativeError.notRegularFile: code = "not_regular_file"
    case FileTransferNativeError.symlinkRejected: code = "symlink_rejected"
    case FileTransferNativeError.sizeOutOfRange: code = "size_out_of_range"
    case FileTransferNativeError.crossVolume: code = "cross_volume"
    case FileTransferNativeError.identityMismatch: code = "identity_mismatch"
    case FileTransferNativeError.collision: code = "commit_collision"
    case FileTransferNativeError.missingFile: code = "missing_file"
    case FileTransferNativeError.insufficientStorage: code = "insufficient_storage"
    default: code = "file_transfer_failed"
    }
    return FlutterError(code: code, message: String(describing: error), details: nil)
  }

  static func activePresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    let window = scenes
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow }) ?? scenes.flatMap(\.windows).first
    var presenter = window?.rootViewController
    while let presented = presenter?.presentedViewController,
      !presented.isBeingDismissed
    {
      presenter = presented
    }
    return presenter
  }
}
