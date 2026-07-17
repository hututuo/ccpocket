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

}
