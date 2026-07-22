import Flutter
import UIKit

/// Versioned inventory of native capabilities compiled into this base IPA.
///
/// Dart OTA code must probe this snapshot before using a native capability.
/// Adding a capability or raising its API version requires a new base IPA;
/// Shorebird patches may only consume capabilities already listed here.
final class MobileHostSnapshotPlugin: NSObject, FlutterPlugin {
  static let channelName = "ccpocket/mobile_host"
  static let schemaVersion = 1
  static let minimumOSMajorVersion = 15

  static let nativeCapabilities: [String: Int] = [
    "permissionHost": 1,
    "fileTransfer": 2,
    "quickLook": 1,
    "share": 1,
    "notifications": 1,
    "speech": 1,
    "webView": 1,
    "secureStorage": 1,
    "database": 1,
    "clipboard": 1,
    "dragDrop": 1,
  ]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(MobileHostSnapshotPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "getSnapshot" else {
      result(FlutterMethodNotImplemented)
      return
    }
    result(Self.snapshot())
  }

  static func snapshot(
    bundle: Bundle = .main,
    osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
  ) -> [String: Any] {
    var value: [String: Any] = [
      "supported": osVersion.majorVersion >= minimumOSMajorVersion,
      "schemaVersion": schemaVersion,
      "platform": "ios",
      "osVersion": [
        "major": osVersion.majorVersion,
        "minor": osVersion.minorVersion,
        "patch": osVersion.patchVersion,
      ],
      "capabilities": nativeCapabilities,
    ]
    if let version = bundle.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String {
      value["baseVersion"] = version
    }
    if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
      value["buildNumber"] = build
    }
    if osVersion.majorVersion < minimumOSMajorVersion {
      value["reason"] = "minimum_ios_\(minimumOSMajorVersion)_required"
    }
    return value
  }
}
