import Flutter
import UserNotifications

struct NotificationApprovalActionPayload: Equatable {
  static let categoryIdentifier = "ccpocket_approval_v1"
  static let approveActionIdentifier = "ccpocket_approve_once_v1"
  static let rejectActionIdentifier = "ccpocket_reject_v1"

  let actionIdentifier: String
  let sessionId: String
  let provider: String
  let providerSessionId: String?
  let permissionId: String
  let occurredAt: String

  var dictionary: [String: String] {
    var value = [
      "actionId": actionIdentifier,
      "sessionId": sessionId,
      "provider": provider,
      "permissionId": permissionId,
      "occurredAt": occurredAt,
    ]
    if let providerSessionId {
      value["providerSessionId"] = providerSessionId
    }
    return value
  }

  static func parse(
    categoryIdentifier: String,
    actionIdentifier: String,
    userInfo: [AnyHashable: Any]
  ) -> NotificationApprovalActionPayload? {
    guard categoryIdentifier == Self.categoryIdentifier else { return nil }
    guard
      actionIdentifier == approveActionIdentifier ||
        actionIdentifier == rejectActionIdentifier
    else {
      return nil
    }

    let fields = notificationFields(userInfo)
    guard
      let sessionId = boundedString(fields["sessionId"], maximumLength: 256),
      let provider = boundedString(fields["provider"], maximumLength: 16),
      provider == "claude" || provider == "codex",
      let eventType = boundedString(fields["eventType"], maximumLength: 64),
      eventType == "approval_required",
      let permissionId = boundedString(fields["permissionId"], maximumLength: 256),
      let occurredAt = boundedString(fields["occurredAt"], maximumLength: 64),
      ISO8601DateFormatter().date(from: occurredAt) != nil
    else {
      return nil
    }
    let providerSessionId = boundedString(
      fields["providerSessionId"],
      maximumLength: 256
    )
    return NotificationApprovalActionPayload(
      actionIdentifier: actionIdentifier,
      sessionId: sessionId,
      provider: provider,
      providerSessionId: providerSessionId,
      permissionId: permissionId,
      occurredAt: occurredAt
    )
  }

  private static func notificationFields(
    _ userInfo: [AnyHashable: Any]
  ) -> [String: Any] {
    if
      let encodedPayload = userInfo["payload"] as? String,
      encodedPayload.utf8.count <= 4_096,
      let data = encodedPayload.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data),
      let fields = decoded as? [String: Any]
    {
      return fields
    }
    return userInfo.reduce(into: [String: Any]()) { result, entry in
      guard let key = entry.key as? String else { return }
      result[key] = entry.value
    }
  }

  private static func boundedString(
    _ value: Any?,
    maximumLength: Int
  ) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
    return trimmed
  }
}

/// Captures approval notification actions from both local and remote sources.
///
/// The native host only forwards opaque identifiers. Dart and Bridge perform
/// the authoritative pending-permission check before any approval is sent.
final class NotificationActionHostPlugin: NSObject, FlutterPlugin {
  static let channelName = "ccpocket/notification_actions"
  static let nativeApiVersion = 1
  private static let maximumPendingActions = 8

  private static let lock = NSLock()
  private static var channel: FlutterMethodChannel?
  private static var dartReady = false
  private static var pending: [NotificationApprovalActionPayload] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let plugin = NotificationActionHostPlugin()
    lock.lock()
    Self.channel = channel
    dartReady = false
    lock.unlock()
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setDartReady" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let queued: [NotificationApprovalActionPayload]
    Self.lock.lock()
    Self.dartReady = true
    queued = Self.pending
    Self.pending.removeAll(keepingCapacity: true)
    Self.lock.unlock()
    for action in queued {
      Self.deliver(action)
    }
    result([
      "supported": true,
      "nativeApiVersion": Self.nativeApiVersion,
      "queuedActionCount": queued.count,
    ])
  }

  @discardableResult
  static func capture(_ response: UNNotificationResponse) -> Bool {
    guard
      let action = NotificationApprovalActionPayload.parse(
        categoryIdentifier: response.notification.request.content.categoryIdentifier,
        actionIdentifier: response.actionIdentifier,
        userInfo: response.notification.request.content.userInfo
      )
    else {
      return false
    }

    lock.lock()
    let canDeliver = dartReady && channel != nil
    if !canDeliver {
      enqueueLocked(action)
    }
    lock.unlock()

    if canDeliver {
      deliver(action)
    }
    return true
  }

  private static func deliver(_ action: NotificationApprovalActionPayload) {
    DispatchQueue.main.async {
      lock.lock()
      let activeChannel = dartReady ? channel : nil
      if activeChannel == nil {
        enqueueLocked(action)
      }
      lock.unlock()
      activeChannel?.invokeMethod(
        "approvalAction",
        arguments: action.dictionary
      )
    }
  }

  /// Adds the latest decision for a permission while `lock` is held.
  private static func enqueueLocked(_ action: NotificationApprovalActionPayload) {
    pending.removeAll {
      $0.provider == action.provider &&
        ($0.providerSessionId ?? $0.sessionId) ==
          (action.providerSessionId ?? action.sessionId) &&
        $0.permissionId == action.permissionId
    }
    pending.append(action)
    if pending.count > maximumPendingActions {
      pending.removeFirst(pending.count - maximumPendingActions)
    }
  }
}
