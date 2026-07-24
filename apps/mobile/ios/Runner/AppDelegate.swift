import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let appIconChannelName = "ccpocket/app_icon"
  private let platformEnvironmentChannelName = "ccpocket/platform_environment"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // BGTaskScheduler requires registration before launch returns. The Flutter
    // channel is attached later by didInitializeImplicitFlutterEngine.
    BackgroundSyncHostPlugin.registerBackgroundRefreshTask()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppIconChannel") {
      let channel = FlutterMethodChannel(
        name: appIconChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handleAppIconMethodCall)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlatformEnvironmentChannel") {
      let channel = FlutterMethodChannel(
        name: platformEnvironmentChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler(handlePlatformEnvironmentMethodCall)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ArtifactQuickLookPlugin") {
      ArtifactQuickLookPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FileTransferPlugin") {
      FileTransferPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PermissionHostPlugin") {
      PermissionHostPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MobileHostSnapshotPlugin") {
      MobileHostSnapshotPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundSyncHostPlugin") {
      BackgroundSyncHostPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "BackgroundLocationKeepAlivePlugin"
    ) {
      BackgroundLocationKeepAlivePlugin.register(with: registrar)
    }
  }

  private func handleAppIconMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "supportsAlternateIcons":
      result(UIApplication.shared.supportsAlternateIcons)
    case "getCurrentIcon":
      result(currentIconId())
    case "setIcon":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_args", message: "Missing arguments", details: nil))
        return
      }
      let icon = args["icon"] as? String
      setAlternateIcon(icon: icon, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handlePlatformEnvironmentMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isIOSAppOnMac":
      if #available(iOS 14.0, *) {
        result(ProcessInfo.processInfo.isiOSAppOnMac)
      } else {
        result(false)
      }
    case "iosUserInterfaceIdiom":
      let idiom = UIDevice.current.userInterfaceIdiom
      if #available(iOS 14.0, *), idiom == .mac {
        result("mac")
        return
      }
      switch idiom {
      case .pad:
        result("pad")
      case .phone:
        result("phone")
      default:
        result("unspecified")
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func currentIconId() -> String? {
    switch UIApplication.shared.alternateIconName {
    case "SupporterLightOutline":
      return "light_outline"
    case "SupporterProCopperEmerald":
      return "pro_copper_emerald"
    default:
      return nil
    }
  }

  private func setAlternateIcon(icon: String?, result: @escaping FlutterResult) {
    guard UIApplication.shared.supportsAlternateIcons else {
      result(FlutterError(code: "unsupported", message: "Alternate icons unsupported", details: nil))
      return
    }

    let iconName: String?
    switch icon {
    case nil, "default":
      iconName = nil
    case "light_outline":
      iconName = "SupporterLightOutline"
    case "pro_copper_emerald":
      iconName = "SupporterProCopperEmerald"
    default:
      result(FlutterError(code: "invalid_icon", message: "Unknown app icon \(icon ?? "nil")", details: nil))
      return
    }

    DispatchQueue.main.async {
      UIApplication.shared.setAlternateIconName(iconName) { error in
        if let error {
          result(
            FlutterError(
              code: "set_icon_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
          return
        }
        result(nil)
      }
    }
  }
}
