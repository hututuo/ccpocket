import Flutter
import CoreLocation
import Photos
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
    XCTAssertEqual(supported["nativeApiVersion"] as? Int, 2)
    XCTAssertEqual(supported["appVersion"] as? String, "1.72.1")

    let unsupported = FileTransferPlugin.supportInfo(
      osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 1)
    )
    XCTAssertEqual(unsupported["supported"] as? Bool, false)
  }

  func testPermissionHostSupportInfoGatesOSAndFreezesNativeAPI() {
    let supported = PermissionHostPlugin.supportInfo(
      osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
      appVersion: "1.107.2",
      buildNumber: "197"
    )
    XCTAssertEqual(supported["supported"] as? Bool, true)
    XCTAssertEqual(supported["nativeApiVersion"] as? Int, 3)
    XCTAssertEqual(supported["appVersion"] as? String, "1.107.2")

    let unsupported = PermissionHostPlugin.supportInfo(
      osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 1)
    )
    XCTAssertEqual(unsupported["supported"] as? Bool, false)
  }

  func testPermissionHostRequestModesFailClosed() {
    XCTAssertEqual(PermissionHostPlugin.requestMode(for: "notDetermined"), "direct")
    XCTAssertEqual(PermissionHostPlugin.requestMode(for: "denied"), "openSettings")
    XCTAssertEqual(PermissionHostPlugin.requestMode(for: "authorized"), "none")
    XCTAssertEqual(PermissionHostPlugin.requestMode(for: "futureStatus"), "unavailable")
  }

  func testPermissionHostPhotoLibraryStatusesAreStable() {
    XCTAssertEqual(PermissionHostPlugin.statusName(PHAuthorizationStatus.notDetermined), "notDetermined")
    XCTAssertEqual(PermissionHostPlugin.statusName(PHAuthorizationStatus.limited), "limited")
    XCTAssertEqual(PermissionHostPlugin.statusName(PHAuthorizationStatus.denied), "denied")
  }

  func testPermissionHostLocationStatusesAndUpgradeModesAreStable() {
    XCTAssertEqual(
      PermissionHostPlugin.statusName(CLAuthorizationStatus.authorizedWhenInUse),
      "authorizedWhenInUse"
    )
    XCTAssertEqual(
      PermissionHostPlugin.statusName(CLAuthorizationStatus.authorizedAlways),
      "authorizedAlways"
    )
    XCTAssertEqual(
      PermissionHostPlugin.requestMode(for: "authorizedWhenInUse"),
      "direct"
    )
    XCTAssertEqual(
      PermissionHostPlugin.requestMode(for: "authorizedAlways"),
      "none"
    )
  }

  func testMobileHostSnapshotIsVersionedAndIncludesRequiredCapabilities() throws {
    let snapshot = MobileHostSnapshotPlugin.snapshot(
      osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
    )

    XCTAssertEqual(snapshot["supported"] as? Bool, true)
    XCTAssertEqual(snapshot["schemaVersion"] as? Int, 1)
    XCTAssertEqual(snapshot["platform"] as? String, "ios")
    let capabilities = try XCTUnwrap(snapshot["capabilities"] as? [String: Int])
    XCTAssertEqual(capabilities["permissionHost"], 3)
    XCTAssertEqual(capabilities["fileTransfer"], 2)
    XCTAssertEqual(capabilities["quickLook"], 1)
    XCTAssertEqual(capabilities["secureStorage"], 1)
    XCTAssertEqual(capabilities["dragDrop"], 1)
    XCTAssertEqual(capabilities["photoLibrary"], 1)
    XCTAssertEqual(capabilities["biometrics"], 1)
    XCTAssertEqual(capabilities["fileMutationBiometricAuth"], 1)
    XCTAssertEqual(capabilities["backgroundContinuation"], 1)
    XCTAssertEqual(capabilities["backgroundRefreshWarmRuntime"], 1)
    XCTAssertEqual(capabilities["backgroundLocationKeepAlive"], 1)
    XCTAssertEqual(capabilities["notificationApprovalActions"], 1)
    XCTAssertNil(capabilities["backgroundAppRefresh"])
  }

  func testNotificationApprovalActionParsesLocalAndRemoteOpaquePayloads() throws {
    let occurredAt = "2026-07-25T01:02:03Z"
    let encoded = try JSONSerialization.data(
      withJSONObject: [
        "sessionId": "runtime-session",
        "provider": "codex",
        "providerSessionId": "durable-thread",
        "bridgeInstanceId": "bridge-1",
        "codexSourceId": "codex-source-1",
        "eventType": "approval_required",
        "permissionId": "opaque-permission",
        "occurredAt": occurredAt,
      ]
    )
    let local = NotificationApprovalActionPayload.parse(
      categoryIdentifier: NotificationApprovalActionPayload.categoryIdentifier,
      actionIdentifier: NotificationApprovalActionPayload.approveActionIdentifier,
      userInfo: ["payload": try XCTUnwrap(String(data: encoded, encoding: .utf8))]
    )
    XCTAssertEqual(local?.sessionId, "runtime-session")
    XCTAssertEqual(local?.providerSessionId, "durable-thread")
    XCTAssertEqual(local?.bridgeInstanceId, "bridge-1")
    XCTAssertEqual(local?.codexSourceId, "codex-source-1")
    XCTAssertNil(local?.bridgeRouteIdentity)
    XCTAssertEqual(local?.permissionId, "opaque-permission")

    let remote = NotificationApprovalActionPayload.parse(
      categoryIdentifier: NotificationApprovalActionPayload.categoryIdentifier,
      actionIdentifier: NotificationApprovalActionPayload.rejectActionIdentifier,
      userInfo: [
        "sessionId": "runtime-session",
        "provider": "claude",
        "eventType": "approval_required",
        "permissionId": "opaque-permission",
        "occurredAt": occurredAt,
        "toolName": "must-not-be-forwarded",
      ]
    )
    XCTAssertEqual(remote?.actionIdentifier, "ccpocket_reject_v1")
    XCTAssertNil(remote?.dictionary["toolName"])
  }

  func testNotificationApprovalActionRejectsWrongCategoryAndQuestionEvents() {
    let fields: [AnyHashable: Any] = [
      "sessionId": "runtime-session",
      "provider": "claude",
      "eventType": "ask_user_question",
      "permissionId": "opaque-permission",
      "occurredAt": "2026-07-25T01:02:03Z",
    ]
    XCTAssertNil(
      NotificationApprovalActionPayload.parse(
        categoryIdentifier: "other",
        actionIdentifier: NotificationApprovalActionPayload.approveActionIdentifier,
        userInfo: fields
      )
    )
    XCTAssertNil(
      NotificationApprovalActionPayload.parse(
        categoryIdentifier: NotificationApprovalActionPayload.categoryIdentifier,
        actionIdentifier: NotificationApprovalActionPayload.approveActionIdentifier,
        userInfo: fields
      )
    )
  }

  func testFileMutationAuthChallengeBoundsAreStable() {
    XCTAssertTrue(FileMutationAuthPlugin.isValidChallengePayload("{\"v\":1}"))
    XCTAssertFalse(FileMutationAuthPlugin.isValidChallengePayload(""))
    XCTAssertFalse(
      FileMutationAuthPlugin.isValidChallengePayload(String(repeating: "x", count: 4_097))
    )
  }

  func testBackgroundLocationKeepAliveFailsClosedForPowerPermissionAndThermalPressure() {
    XCTAssertNil(
      BackgroundLocationKeepAlivePlugin.eligibilityPauseReason(
        authorization: .authorizedAlways,
        locationServicesEnabled: true,
        lowPowerModeEnabled: false,
        thermalState: .nominal
      )
    )
    XCTAssertEqual(
      BackgroundLocationKeepAlivePlugin.eligibilityPauseReason(
        authorization: .authorizedWhenInUse,
        locationServicesEnabled: true,
        lowPowerModeEnabled: false,
        thermalState: .nominal
      ),
      "location_always_required"
    )
    XCTAssertEqual(
      BackgroundLocationKeepAlivePlugin.eligibilityPauseReason(
        authorization: .authorizedAlways,
        locationServicesEnabled: true,
        lowPowerModeEnabled: true,
        thermalState: .nominal
      ),
      "low_power_mode"
    )
    XCTAssertEqual(
      BackgroundLocationKeepAlivePlugin.eligibilityPauseReason(
        authorization: .authorizedAlways,
        locationServicesEnabled: true,
        lowPowerModeEnabled: false,
        thermalState: .serious
      ),
      "thermal_pressure"
    )
  }

  func testMobileHostSnapshotFailsClosedBelowMinimumIOS() throws {
    let snapshot = MobileHostSnapshotPlugin.snapshot(
      osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 8, patchVersion: 0)
    )

    XCTAssertEqual(snapshot["supported"] as? Bool, false)
    XCTAssertEqual(snapshot["reason"] as? String, "minimum_ios_15_required")
  }

  func testBackgroundContinuationGenerationIsIdempotentAndFenced() {
    var nextIdentifier = 0
    var beginCount = 0
    var ended: [Int] = []
    let controller = BackgroundContinuationController(
      begin: { _, _ in
        beginCount += 1
        nextIdentifier += 1
        return UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
      },
      end: { identifier in
        ended.append(identifier.rawValue)
      }
    )

    XCTAssertTrue(
      controller.begin(generation: 1, reason: "test") { _ in }
    )
    XCTAssertTrue(
      controller.begin(generation: 1, reason: "duplicate") { _ in }
    )
    XCTAssertEqual(beginCount, 1)
    XCTAssertTrue(
      controller.begin(generation: 2, reason: "new-generation") { _ in }
    )
    XCTAssertEqual(beginCount, 2)
    XCTAssertEqual(ended, [1])
    XCTAssertFalse(controller.end(generation: 1))
    XCTAssertEqual(ended, [1])
    XCTAssertTrue(controller.end(generation: 2))
    XCTAssertEqual(ended, [1, 2])
  }

  func testBackgroundRefreshCompletionRunsExactlyOnce() {
    var values: [Bool] = []
    let completion = BackgroundRefreshCompletion { values.append($0) }

    XCTAssertTrue(completion.finish(success: false))
    XCTAssertFalse(completion.finish(success: true))
    XCTAssertEqual(values, [false])
  }

  func testBackgroundRefreshPendingRunIsTakenOverOnceWhenChannelBecomesReady() {
    let now = Date(timeIntervalSince1970: 100)
    let controller = BackgroundRefreshPendingController(now: { now })
    var operationCompletion: ((Bool) -> Void)?
    var startedRunIds: [String] = []
    var finishedValues: [Bool] = []

    XCTAssertEqual(
      controller.enqueue(
        runId: "runtime-startup",
        deadline: now.addingTimeInterval(25),
        finish: { finishedValues.append($0) }
      ),
      .waitingForEndpoint
    )
    XCTAssertEqual(controller.state, .waiting(runId: "runtime-startup"))

    let endpoint = BackgroundRefreshEndpoint(
      perform: { runId, _, completion in
        startedRunIds.append(runId)
        operationCompletion = completion
      },
      expire: { _ in }
    )
    controller.attach(endpoint: endpoint)
    controller.attach(endpoint: endpoint)

    XCTAssertEqual(startedRunIds, ["runtime-startup"])
    XCTAssertEqual(controller.state, .running(runId: "runtime-startup"))

    operationCompletion?(true)
    operationCompletion?(false)
    XCTAssertEqual(finishedValues, [true])
    XCTAssertEqual(controller.state, .idle)
    XCTAssertFalse(controller.expire(runId: "runtime-startup"))
  }

  func testBackgroundRefreshPendingControllerRejectsDuplicateAndExpiresOldPending() {
    final class TestClock {
      var value = Date(timeIntervalSince1970: 100)
    }

    let clock = TestClock()
    let controller = BackgroundRefreshPendingController(now: { clock.value })
    var firstFinishes: [Bool] = []
    var duplicateFinishes: [Bool] = []
    var startedRunIds: [String] = []
    var freshOperationCompletion: ((Bool) -> Void)?

    XCTAssertEqual(
      controller.enqueue(
        runId: "first",
        deadline: clock.value.addingTimeInterval(10),
        finish: { firstFinishes.append($0) }
      ),
      .waitingForEndpoint
    )
    XCTAssertEqual(
      controller.enqueue(
        runId: "duplicate",
        deadline: clock.value.addingTimeInterval(10),
        finish: { duplicateFinishes.append($0) }
      ),
      .rejectedBusy
    )
    XCTAssertEqual(duplicateFinishes, [false])
    XCTAssertEqual(controller.state, .waiting(runId: "first"))

    clock.value = clock.value.addingTimeInterval(11)
    controller.attach(
      endpoint: BackgroundRefreshEndpoint(
        perform: { runId, _, completion in
          startedRunIds.append(runId)
          freshOperationCompletion = completion
        },
        expire: { _ in }
      )
    )

    XCTAssertEqual(startedRunIds, [])
    XCTAssertEqual(firstFinishes, [false])
    XCTAssertEqual(controller.state, .idle)
    XCTAssertFalse(controller.expire(runId: "first"))

    XCTAssertEqual(
      controller.enqueue(
        runId: "fresh",
        deadline: clock.value.addingTimeInterval(10),
        finish: { firstFinishes.append($0) }
      ),
      .started
    )
    XCTAssertEqual(startedRunIds, ["fresh"])
    freshOperationCompletion?(true)
    XCTAssertEqual(firstFinishes, [false, true])
    XCTAssertEqual(controller.state, .idle)
  }

  func testBackgroundRefreshExpirationNotifiesOnlyStartedMatchingRun() {
    let now = Date(timeIntervalSince1970: 100)
    let controller = BackgroundRefreshPendingController(now: { now })
    var operationCompletion: ((Bool) -> Void)?
    var expiredRunIds: [String] = []
    var finishedValues: [Bool] = []

    controller.attach(
      endpoint: BackgroundRefreshEndpoint(
        perform: { _, _, completion in operationCompletion = completion },
        expire: { expiredRunIds.append($0) }
      )
    )
    XCTAssertEqual(
      controller.enqueue(
        runId: "active",
        deadline: now.addingTimeInterval(25),
        finish: { finishedValues.append($0) }
      ),
      .started
    )

    XCTAssertTrue(controller.expire(runId: "active"))
    XCTAssertFalse(controller.expire(runId: "active"))
    operationCompletion?(true)

    XCTAssertEqual(expiredRunIds, ["active"])
    XCTAssertEqual(finishedValues, [false])
    XCTAssertEqual(controller.state, .idle)
  }

  func testBackgroundRefreshEndpointReplacementFailsRunningButKeepsPending() {
    let now = Date(timeIntervalSince1970: 100)
    let controller = BackgroundRefreshPendingController(now: { now })
    var expiredRunIds: [String] = []
    var finishedValues: [Bool] = []

    controller.attach(
      endpoint: BackgroundRefreshEndpoint(
        perform: { _, _, _ in },
        expire: { expiredRunIds.append($0) }
      )
    )
    XCTAssertEqual(
      controller.enqueue(
        runId: "old-engine",
        deadline: now.addingTimeInterval(25),
        finish: { finishedValues.append($0) }
      ),
      .started
    )

    controller.detachEndpoint()
    XCTAssertEqual(expiredRunIds, ["old-engine"])
    XCTAssertEqual(finishedValues, [false])
    XCTAssertEqual(controller.state, .idle)

    XCTAssertEqual(
      controller.enqueue(
        runId: "new-engine",
        deadline: now.addingTimeInterval(25),
        finish: { finishedValues.append($0) }
      ),
      .waitingForEndpoint
    )
    controller.detachEndpoint()
    XCTAssertEqual(controller.state, .waiting(runId: "new-engine"))
    XCTAssertEqual(finishedValues, [false])
  }

  func testBackgroundRefreshIdentifierMatchesInfoPlist() throws {
    let bundle = Bundle(for: AppDelegate.self)
    let identifiers = try XCTUnwrap(
      bundle.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
        as? [String]
    )

    XCTAssertTrue(
      identifiers.contains(BackgroundSyncHostPlugin.refreshTaskIdentifier)
    )
  }

}
