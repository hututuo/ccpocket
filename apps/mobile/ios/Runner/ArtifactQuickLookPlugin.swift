import Flutter
import QuickLook
import UIKit

enum ArtifactQuickLookValidationError: Error, Equatable {
  case invalidPath
  case outsideSandbox
  case fileNotFound
}

final class ArtifactQuickLookItem: NSObject, QLPreviewItem {
  let previewItemURL: URL?
  let previewItemTitle: String?

  init(url: URL, title: String?) {
    previewItemURL = url
    previewItemTitle = title
  }
}

final class ArtifactQuickLookSession: NSObject, QLPreviewControllerDataSource,
  QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate
{
  weak var owner: ArtifactQuickLookPlugin?
  let controller: QLPreviewController
  private let item: ArtifactQuickLookItem
  private var result: FlutterResult?

  init(item: ArtifactQuickLookItem, result: @escaping FlutterResult) {
    self.item = item
    self.result = result
    controller = QLPreviewController()
    super.init()
    controller.dataSource = self
    controller.delegate = self
    controller.modalPresentationStyle = .fullScreen
  }

  func complete(_ value: Any?) {
    guard let result else { return }
    self.result = nil
    result(value)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return 1
  }

  func previewController(
    _ controller: QLPreviewController,
    previewItemAt index: Int
  ) -> QLPreviewItem {
    return item
  }

  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    owner?.finish(self)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    owner?.finish(self)
  }

  func previewController(
    _ controller: QLPreviewController,
    shouldOpen url: URL,
    for item: QLPreviewItem
  ) -> Bool {
    // Artifact previews are deliberately read-only and self-contained. Links
    // inside a document must not escape the preview without an explicit app UI.
    return false
  }

  func previewController(
    _ controller: QLPreviewController,
    editingModeFor previewItem: QLPreviewItem
  ) -> QLPreviewItemEditingMode {
    return .disabled
  }
}

final class ArtifactQuickLookPlugin: NSObject, FlutterPlugin {
  static let channelName = "ccpocket/artifact_quick_look"

  private var activeSession: ArtifactQuickLookSession?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(ArtifactQuickLookPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "previewFile" else {
      result(FlutterMethodNotImplemented)
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(
          FlutterError(
            code: "unavailable",
            message: "Quick Look is unavailable",
            details: nil
          )
        )
        return
      }
      self.previewFile(arguments: call.arguments, result: result)
    }
  }

  static func validatedFileURL(
    path: String,
    homeDirectoryURL: URL = URL(
      fileURLWithPath: NSHomeDirectory(),
      isDirectory: true
    ),
    fileManager: FileManager = .default
  ) throws -> URL {
    guard !path.isEmpty,
      !path.unicodeScalars.contains(where: { $0.value == 0 }),
      (path as NSString).isAbsolutePath
    else {
      throw ArtifactQuickLookValidationError.invalidPath
    }

    let homeURL = homeDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    let fileURL = URL(fileURLWithPath: path, isDirectory: false)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let homeComponents = homeURL.pathComponents
    let fileComponents = fileURL.pathComponents
    guard fileComponents.count > homeComponents.count,
      Array(fileComponents.prefix(homeComponents.count)) == homeComponents
    else {
      throw ArtifactQuickLookValidationError.outsideSandbox
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw ArtifactQuickLookValidationError.fileNotFound
    }
    return fileURL
  }

  fileprivate func finish(_ session: ArtifactQuickLookSession, error: FlutterError? = nil) {
    guard activeSession === session else { return }
    activeSession = nil
    if let error {
      session.complete(error)
    } else {
      session.complete(nil)
    }
  }

  private func previewFile(arguments: Any?, result: @escaping FlutterResult) {
    guard activeSession == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Another artifact preview is already open",
          details: nil
        )
      )
      return
    }
    guard let arguments = arguments as? [String: Any],
      let path = arguments["path"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "previewFile requires an absolute path",
          details: nil
        )
      )
      return
    }
    if let suppliedTitle = arguments["title"], !(suppliedTitle is String) {
      result(
        FlutterError(
          code: "invalid_args",
          message: "title must be a string",
          details: nil
        )
      )
      return
    }

    let title = (arguments["title"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fileURL: URL
    do {
      fileURL = try Self.validatedFileURL(path: path)
    } catch ArtifactQuickLookValidationError.invalidPath,
      ArtifactQuickLookValidationError.outsideSandbox
    {
      result(
        FlutterError(
          code: "invalid_path",
          message: "The preview file must be inside the app sandbox",
          details: nil
        )
      )
      return
    } catch ArtifactQuickLookValidationError.fileNotFound {
      result(
        FlutterError(
          code: "file_not_found",
          message: "The preview file does not exist",
          details: nil
        )
      )
      return
    } catch {
      result(
        FlutterError(
          code: "invalid_path",
          message: "The preview file path is invalid",
          details: nil
        )
      )
      return
    }

    let item = ArtifactQuickLookItem(
      url: fileURL,
      title: title?.isEmpty == false ? title : nil
    )
    guard QLPreviewController.canPreview(item) else {
      result(
        FlutterError(
          code: "unsupported",
          message: "Quick Look cannot preview this file",
          details: nil
        )
      )
      return
    }
    guard let presenter = Self.activePresenter() else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "No active window is available for Quick Look",
          details: nil
        )
      )
      return
    }
    guard presenter.viewIfLoaded?.window != nil,
      !presenter.isBeingDismissed,
      !presenter.isBeingPresented
    else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "The active window is not ready for Quick Look",
          details: nil
        )
      )
      return
    }

    let session = ArtifactQuickLookSession(item: item, result: result)
    session.owner = self
    activeSession = session
    presenter.present(session.controller, animated: true) { [weak self, weak session] in
      guard let self, let session, self.activeSession === session else { return }
      session.controller.presentationController?.delegate = session
      guard session.controller.presentingViewController != nil else {
        self.finish(
          session,
          error: FlutterError(
            code: "presentation_failed",
            message: "Quick Look could not be presented",
            details: nil
          )
        )
        return
      }
    }
  }

  private static func activePresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted { lhs, rhs in
        let lhsActive = lhs.activationState == .foregroundActive
        let rhsActive = rhs.activationState == .foregroundActive
        return lhsActive && !rhsActive
      }
    for scene in scenes where scene.activationState == .foregroundActive {
      let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        ?? scene.windows.first(where: { !$0.isHidden })?.rootViewController
      if let root {
        return topViewController(from: root)
      }
    }
    return nil
  }

  private static func topViewController(from controller: UIViewController) -> UIViewController {
    if let presented = controller.presentedViewController,
      !presented.isBeingDismissed
    {
      return topViewController(from: presented)
    }
    if let navigation = controller as? UINavigationController,
      let visible = navigation.visibleViewController
    {
      return topViewController(from: visible)
    }
    if let tabs = controller as? UITabBarController,
      let selected = tabs.selectedViewController
    {
      return topViewController(from: selected)
    }
    if let split = controller as? UISplitViewController,
      let last = split.viewControllers.last
    {
      return topViewController(from: last)
    }
    return controller
  }
}
