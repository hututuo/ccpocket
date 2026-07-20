import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testQuickLookValidationAcceptsFileInsideHome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let file = home.appendingPathComponent("artifact.xlsx")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: file)

    let validated = try ArtifactQuickLookPlugin.validatedFileURL(
      path: file.path,
      homeDirectoryURL: home
    )

    XCTAssertEqual(validated, file.standardizedFileURL.resolvingSymlinksInPath())
  }

  func testQuickLookValidationRejectsRelativeAndMissingPaths() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    XCTAssertThrowsError(
      try ArtifactQuickLookPlugin.validatedFileURL(
        path: "artifact.xlsx",
        homeDirectoryURL: home
      )
    ) { error in
      XCTAssertEqual(error as? ArtifactQuickLookValidationError, .invalidPath)
    }
    XCTAssertThrowsError(
      try ArtifactQuickLookPlugin.validatedFileURL(
        path: home.appendingPathComponent("missing.xlsx").path,
        homeDirectoryURL: home
      )
    ) { error in
      XCTAssertEqual(error as? ArtifactQuickLookValidationError, .fileNotFound)
    }
  }

  func testQuickLookValidationRejectsSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let outside = root.appendingPathComponent("outside.xlsx")
    let link = home.appendingPathComponent("link.xlsx")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    XCTAssertThrowsError(
      try ArtifactQuickLookPlugin.validatedFileURL(
        path: link.path,
        homeDirectoryURL: home
      )
    ) { error in
      XCTAssertEqual(error as? ArtifactQuickLookValidationError, .outsideSandbox)
    }
  }

  func testFileTransferSanitizesLeafNamesWithinUtf8Budget() {
    XCTAssertEqual(
      FileTransferPlugin.sanitizedFilename("../bad\\name\u{0000}.zip"),
      ".._bad_name_.zip"
    )
    let long = String(repeating: "报告", count: 100) + ".zip"
    XCTAssertLessThanOrEqual(
      FileTransferPlugin.sanitizedFilename(long).utf8.count,
      240
    )
  }

  func testFileTransferPickerCopyStreamsAndMarksTransient() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source.bin")
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1, 2, 3, 4]).write(to: source)

    let result = try FileTransferPlugin.copyPickedFile(
      source,
      maximumBytes: 4,
      stagingRootURL: staging
    )
    let copied = URL(fileURLWithPath: result["path"] as! String)
    XCTAssertEqual(result["sizeBytes"] as? Int64, 4)
    XCTAssertEqual(try Data(contentsOf: copied), Data([1, 2, 3, 4]))
    let values = try copied.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testFileTransferPickerRejectsOversizeDirectoryAndSymlink() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source.bin")
    let link = root.appendingPathComponent("source-link.bin")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)

    XCTAssertThrowsError(
      try FileTransferPlugin.copyPickedFile(
        source,
        maximumBytes: 2,
        stagingRootURL: root.appendingPathComponent("oversize")
      )
    ) { error in
      XCTAssertEqual(error as? FileTransferNativeError, .sizeOutOfRange)
    }
    XCTAssertThrowsError(
      try FileTransferPlugin.copyPickedFile(
        root,
        maximumBytes: 100,
        stagingRootURL: root.appendingPathComponent("directory")
      )
    ) { error in
      XCTAssertEqual(error as? FileTransferNativeError, .notRegularFile)
    }
    XCTAssertThrowsError(
      try FileTransferPlugin.copyPickedFile(
        link,
        maximumBytes: 100,
        stagingRootURL: root.appendingPathComponent("symlink")
      )
    ) { error in
      XCTAssertEqual(error as? FileTransferNativeError, .symlinkRejected)
    }
  }

  func testFileTransferValidationRejectsPartialFinalAndDirectoryLeafSymlinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let regular = root.appendingPathComponent("regular.part")
    let partialLink = root.appendingPathComponent("partial.part")
    let finalLink = root.appendingPathComponent("final.bin")
    let directory = root.appendingPathComponent("downloads", isDirectory: true)
    let directoryLink = root.appendingPathComponent("downloads-link", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1]).write(to: regular)
    try FileManager.default.createSymbolicLink(at: partialLink, withDestinationURL: regular)
    try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: regular)
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)

    for (url, mustExist) in [
      (partialLink, true),
      (partialLink, false),
      (finalLink, false),
      (directoryLink, true),
    ] {
      XCTAssertThrowsError(
        try FileTransferPlugin.validatedSandboxURL(
          path: url.path,
          homeDirectoryURL: root,
          mustExist: mustExist
        )
      ) { error in
        XCTAssertEqual(error as? FileTransferNativeError, .symlinkRejected)
      }
    }
  }

  func testFileTransferHardLinkCommitIsNoClobberAndCrashRecoverable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let partial = root.appendingPathComponent("transfer.part")
    let final = root.appendingPathComponent("report.bin")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([4, 5, 6]).write(to: partial)
    try FileTransferPlugin.markTransient(partial)

    let identifier = try FileTransferPlugin.linkNoClobber(
      partial: partial,
      final: final
    )
    var probe = try FileTransferPlugin.probeCommit(
      partial: partial,
      final: final,
      expectedIdentifier: nil
    )
    XCTAssertEqual(probe["state"] as? String, "linked")
    XCTAssertEqual(probe["resourceIdentifier"] as? String, identifier)
    let linkedValues = try final.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(linkedValues.isExcludedFromBackup, false)

    try FileTransferPlugin.finalizeLinkedCommit(
      partial: partial,
      final: final,
      expectedIdentifier: identifier
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    probe = try FileTransferPlugin.probeCommit(
      partial: partial,
      final: final,
      expectedIdentifier: identifier
    )
    XCTAssertEqual(probe["state"] as? String, "complete")

    let second = root.appendingPathComponent("second.part")
    try Data([9]).write(to: second)
    XCTAssertThrowsError(
      try FileTransferPlugin.linkNoClobber(partial: second, final: final)
    ) { error in
      XCTAssertEqual(error as? FileTransferNativeError, .collision)
    }
  }

  func testFileTransferCapacityIsInt64AndPositive() throws {
    let capacity = try FileTransferPlugin.availableCapacity(
      at: FileManager.default.temporaryDirectory
    )
    XCTAssertNotNil(capacity)
    XCTAssertGreaterThan(capacity ?? 0, 0)
  }

  func testFileTransferSupportInfoGatesOSAndFreezesNativeAPI() {
    let supported = FileTransferPlugin.supportInfo(
      osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
      appVersion: "1.72.1",
      buildNumber: "42"
    )
    XCTAssertEqual(supported["supported"] as? Bool, true)
    XCTAssertEqual(supported["iosMajor"] as? Int, 26)
    XCTAssertEqual(supported["nativeApiVersion"] as? Int, 1)
    XCTAssertEqual(supported["appVersion"] as? String, "1.72.1")

    let unsupported = FileTransferPlugin.supportInfo(
      osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 1)
    )
    XCTAssertEqual(unsupported["supported"] as? Bool, false)
  }

}
