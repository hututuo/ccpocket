import CoreLocation
import Flutter
import UIKit

/// Optional, user-authorized host primitive for a lightweight background
/// notification connection.
///
/// Location values are deliberately ignored. Dart may start this primitive
/// only while an agent turn is active. It may be pre-armed during iOS'
/// foreground-to-background transition; full stream delivery is disabled as
/// soon as the app reaches the background lifecycle state.
final class BackgroundLocationKeepAlivePlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  static let channelName = "ccpocket/background_location_keep_alive"
  static let nativeAPIVersion = 1

  private let channel: FlutterMethodChannel
  private let manager: CLLocationManager
  private var active = false
  private var pauseReason: String?
  private var observers: [NSObjectProtocol] = []

  init(channel: FlutterMethodChannel, manager: CLLocationManager = CLLocationManager()) {
    self.channel = channel
    self.manager = manager
    super.init()
    manager.delegate = self
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleResourcePressure()
      }
    )
    observers.append(
      NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleResourcePressure()
      }
    )
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let plugin = BackgroundLocationKeepAlivePlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      switch call.method {
      case "getSnapshot":
        result(self.snapshot())
      case "start":
        self.start(result: result)
      case "stop":
        self.stop()
        result(self.snapshot())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func eligibilityPauseReason(
    authorization: CLAuthorizationStatus,
    locationServicesEnabled: Bool,
    lowPowerModeEnabled: Bool,
    thermalState: ProcessInfo.ThermalState
  ) -> String? {
    guard locationServicesEnabled else { return "location_services_disabled" }
    guard authorization == .authorizedAlways else {
      return authorization == .denied || authorization == .restricted
        ? "location_permission_blocked"
        : "location_always_required"
    }
    if lowPowerModeEnabled { return "low_power_mode" }
    if thermalState == .serious || thermalState == .critical {
      return "thermal_pressure"
    }
    return nil
  }

  static func authorizationName(_ status: CLAuthorizationStatus) -> String {
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

  private func start(result: @escaping FlutterResult) {
    let reason = currentEligibilityPauseReason()
    guard reason == nil else {
      pauseReason = reason
      stopLocationUpdates()
      result(snapshot())
      return
    }

    // Coarse, distance-filtered updates are enough to keep the authorized
    // background execution class alive. CC Pocket never reads or transmits
    // the CLLocation payload.
    manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    manager.distanceFilter = 1_000
    manager.activityType = .other
    manager.pausesLocationUpdatesAutomatically = false
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
    manager.startUpdatingLocation()
    active = true
    pauseReason = nil
    result(snapshot())
  }

  private func stop() {
    pauseReason = nil
    stopLocationUpdates()
  }

  private func stopLocationUpdates() {
    if active {
      manager.stopUpdatingLocation()
    }
    active = false
  }

  private func currentEligibilityPauseReason() -> String? {
    Self.eligibilityPauseReason(
      authorization: manager.authorizationStatus,
      locationServicesEnabled: CLLocationManager.locationServicesEnabled(),
      lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalState: ProcessInfo.processInfo.thermalState
    )
  }

  private func handleResourcePressure() {
    guard active, let reason = currentEligibilityPauseReason() else { return }
    pauseReason = reason
    stopLocationUpdates()
    channel.invokeMethod("statusChanged", arguments: snapshot())
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard active, let reason = currentEligibilityPauseReason() else {
      channel.invokeMethod("statusChanged", arguments: snapshot())
      return
    }
    pauseReason = reason
    stopLocationUpdates()
    channel.invokeMethod("statusChanged", arguments: snapshot())
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // Intentionally empty: coordinates never leave Core Location.
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    let locationError = error as? CLError
    guard locationError?.code != .locationUnknown else { return }
    pauseReason = "location_runtime_error"
    stopLocationUpdates()
    channel.invokeMethod("statusChanged", arguments: snapshot())
  }

  private func snapshot() -> [String: Any] {
    let reason = active ? currentEligibilityPauseReason() : pauseReason
    var value: [String: Any] = [
      "supported": true,
      "nativeApiVersion": Self.nativeAPIVersion,
      "authorization": Self.authorizationName(manager.authorizationStatus),
      "active": active,
      "lowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "thermalState": Self.thermalStateName(ProcessInfo.processInfo.thermalState),
    ]
    if let reason {
      value["pauseReason"] = reason
    }
    return value
  }

  private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown"
    }
  }
}
