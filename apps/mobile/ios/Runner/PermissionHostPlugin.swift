import AVFoundation
import CoreLocation
import Flutter
import Photos
import Speech
import UIKit
import UserNotifications

/// Versioned native permission surface for the long-lived mobile host.
///
/// This plugin only exposes permissions already compiled into the app. The
/// Bridge may declare one of the stable permission identifiers, but requesting
/// it remains an explicit Flutter UI action. iOS permissions without a query or
/// request API are reported as system-managed instead of being guessed.
final class PermissionHostPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  static let channelName = "ccpocket/permission_host"
  static let nativeAPIVersion = 3
  static let minimumOSMajorVersion = 15
  static let permissionIds = [
    "notifications",
    "camera",
    "photoLibrary",
    "microphone",
    "speechRecognition",
    "locationAlways",
    "localNetwork",
    "files",
    "biometrics",
  ]

  private lazy var locationManager: CLLocationManager = {
    let manager = CLLocationManager()
    manager.delegate = self
    return manager
  }()
  private var pendingLocationResult: FlutterResult?
  private var shouldUpgradeLocationRequest = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(PermissionHostPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSnapshot":
      completeSnapshot(result)
    case "requestPermission":
      requestPermission(arguments: call.arguments, result: result)
    case "openAppSettings":
      openAppSettings(result: result)
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
      "nativeApiVersion": nativeAPIVersion,
      "iosMajor": osVersion.majorVersion,
      "iosMinor": osVersion.minorVersion,
      "iosPatch": osVersion.patchVersion,
    ]
    if let appVersion { value["appVersion"] = appVersion }
    if let buildNumber { value["buildNumber"] = buildNumber }
    return value
  }

  private func completeSnapshot(_ result: @escaping FlutterResult) {
    snapshot { value in
      DispatchQueue.main.async {
        result(value)
      }
    }
  }

  private func snapshot(completion: @escaping ([String: Any]) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      var value = Self.supportInfo(
        osVersion: ProcessInfo.processInfo.operatingSystemVersion,
        appVersion: Bundle.main.object(
          forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        buildNumber: Bundle.main.object(
          forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
      )
      value["permissions"] = Self.permissionSnapshot(
        notificationStatus: settings.authorizationStatus
      )
      completion(value)
    }
  }

  static func permissionSnapshot(
    notificationStatus: UNAuthorizationStatus
  ) -> [String: [String: String]] {
    let notification = statusName(notificationStatus)
    let camera = cameraStatusName()
    let photoLibrary = statusName(
      PHPhotoLibrary.authorizationStatus(for: .readWrite)
    )
    let microphone = microphoneStatusName()
    let speechRecognition = statusName(SFSpeechRecognizer.authorizationStatus())
    let locationAlways = statusName(CLLocationManager.authorizationStatus())

    return [
      "notifications": entry(
        status: notification,
        requestMode: requestMode(for: notification)
      ),
      "camera": entry(
        status: camera,
        requestMode: requestMode(for: camera)
      ),
      "photoLibrary": entry(
        status: photoLibrary,
        requestMode: requestMode(for: photoLibrary)
      ),
      "microphone": entry(
        status: microphone,
        requestMode: requestMode(for: microphone)
      ),
      "speechRecognition": entry(
        status: speechRecognition,
        requestMode: requestMode(for: speechRecognition)
      ),
      "locationAlways": entry(
        status: locationAlways,
        requestMode: requestMode(for: locationAlways)
      ),
      "localNetwork": entry(
        status: "systemManaged",
        requestMode: "featureTriggered"
      ),
      "files": entry(status: "systemManaged", requestMode: "systemPicker"),
      "biometrics": entry(
        status: "systemManaged",
        requestMode: "featureTriggered"
      ),
    ]
  }

  static func entry(status: String, requestMode: String) -> [String: String] {
    ["status": status, "requestMode": requestMode]
  }

  static func requestMode(for status: String) -> String {
    switch status {
    case "notDetermined", "authorizedWhenInUse":
      return "direct"
    case "denied", "restricted":
      return "openSettings"
    case "authorized", "authorizedAlways", "limited", "provisional", "ephemeral":
      return "none"
    default:
      return "unavailable"
    }
  }

  static func statusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .authorized:
      return "authorized"
    case .provisional:
      return "provisional"
    case .ephemeral:
      return "ephemeral"
    @unknown default:
      return "unknown"
    }
  }

  static func statusName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    case .denied:
      return "denied"
    case .authorized:
      return "authorized"
    @unknown default:
      return "unknown"
    }
  }

  static func statusName(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .authorized:
      return "authorized"
    @unknown default:
      return "unknown"
    }
  }

  static func statusName(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    case .denied:
      return "denied"
    case .authorized:
      return "authorized"
    case .limited:
      return "limited"
    @unknown default:
      return "unknown"
    }
  }

  static func statusName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    case .denied:
      return "denied"
    case .authorizedAlways:
      return "authorizedAlways"
    case .authorizedWhenInUse:
      return "authorizedWhenInUse"
    @unknown default:
      return "unknown"
    }
  }

  private static func cameraStatusName() -> String {
    statusName(AVCaptureDevice.authorizationStatus(for: .video))
  }

  private static func microphoneStatusName() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .undetermined:
        return "notDetermined"
      case .denied:
        return "denied"
      case .granted:
        return "authorized"
      @unknown default:
        return "unknown"
      }
    }

    switch AVAudioSession.sharedInstance().recordPermission {
    case .undetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .granted:
      return "authorized"
    @unknown default:
      return "unknown"
    }
  }

  private func requestPermission(
    arguments: Any?,
    result: @escaping FlutterResult
  ) {
    guard
      let arguments = arguments as? [String: Any],
      let permissionId = arguments["permissionId"] as? String,
      Self.permissionIds.contains(permissionId)
    else {
      result(
        FlutterError(
          code: "unsupported_permission",
          message: "Unknown or missing permission identifier",
          details: ["supportedPermissionIds": Self.permissionIds]
        )
      )
      return
    }

    switch permissionId {
    case "notifications":
      requestNotifications(result: result)
    case "camera":
      AVCaptureDevice.requestAccess(for: .video) { _ in
        self.completeSnapshot(result)
      }
    case "photoLibrary":
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
        self.completeSnapshot(result)
      }
    case "microphone":
      requestMicrophone(result: result)
    case "speechRecognition":
      SFSpeechRecognizer.requestAuthorization { _ in
        self.completeSnapshot(result)
      }
    case "locationAlways":
      requestLocationAlways(result: result)
    case "localNetwork", "files", "biometrics":
      // iOS presents these prompts only from the feature operation itself.
      completeSnapshot(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestLocationAlways(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      guard self.pendingLocationResult == nil else {
        result(
          FlutterError(
            code: "permission_request_in_progress",
            message: "A location permission request is already in progress",
            details: nil
          )
        )
        return
      }
      switch self.locationManager.authorizationStatus {
      case .notDetermined:
        self.pendingLocationResult = result
        self.shouldUpgradeLocationRequest = true
        self.locationManager.requestWhenInUseAuthorization()
      case .authorizedWhenInUse:
        self.locationManager.requestAlwaysAuthorization()
        // Choosing "Keep Only While Using" does not guarantee another
        // authorization callback. Release the Flutter request now; the
        // independent background-location host reports any later upgrade.
        self.completeSnapshot(result)
      case .authorizedAlways, .denied, .restricted:
        self.completeSnapshot(result)
      @unknown default:
        self.completeSnapshot(result)
      }
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let result = pendingLocationResult else { return }
    switch manager.authorizationStatus {
    case .notDetermined:
      return
    case .authorizedWhenInUse where shouldUpgradeLocationRequest:
      pendingLocationResult = nil
      shouldUpgradeLocationRequest = false
      manager.requestAlwaysAuthorization()
      // The Always prompt may finish without another delegate callback.
      completeSnapshot(result)
    default:
      pendingLocationResult = nil
      shouldUpgradeLocationRequest = false
      completeSnapshot(result)
    }
  }

  private func requestNotifications(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { _, error in
      if let error {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "permission_request_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
        return
      }
      self.completeSnapshot(result)
    }
  }

  private func requestMicrophone(result: @escaping FlutterResult) {
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { _ in
        self.completeSnapshot(result)
      }
      return
    }
    AVAudioSession.sharedInstance().requestRecordPermission { _ in
      self.completeSnapshot(result)
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url, options: [:]) { success in
        result(success)
      }
    }
  }
}
