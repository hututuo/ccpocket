import Flutter
import UserNotifications

struct NotificationApprovalActionPayload: Equatable {
  static let categoryIdentifier = "ccpocket_approval_v1"
  static let codexBrokerCategoryIdentifier = "ccpocket_approval_v2"
  static let approveActionIdentifier = "ccpocket_approve_once_v1"
  static let rejectActionIdentifier = "ccpocket_reject_v1"

  let actionIdentifier: String
  let sessionId: String
  let provider: String
  let providerSessionId: String?
  let bridgeInstanceId: String?
  let codexSourceId: String?
  let bridgeRouteIdentity: String?
  let permissionId: String
  let occurredAt: String
  let actionPayloadVersion: Int
  let threadId: String?
  let turnId: String?
  let authorityGeneration: String?
  let allowedActions: String?

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
    if let bridgeInstanceId {
      value["bridgeInstanceId"] = bridgeInstanceId
    }
    if let codexSourceId {
      value["codexSourceId"] = codexSourceId
    }
    if let bridgeRouteIdentity {
      value["bridgeRouteIdentity"] = bridgeRouteIdentity
    }
    if actionPayloadVersion == 2 {
      value["actionPayloadVersion"] = "2"
      value["opaqueRequestId"] = permissionId
      if let threadId { value["threadId"] = threadId }
      if let turnId { value["turnId"] = turnId }
      if let authorityGeneration {
        value["authorityGeneration"] = authorityGeneration
      }
      if let allowedActions { value["allowedActions"] = allowedActions }
    }
    return value
  }

  static func parse(
    categoryIdentifier: String,
    actionIdentifier: String,
    userInfo: [AnyHashable: Any]
  ) -> NotificationApprovalActionPayload? {
    let isCodexBroker = categoryIdentifier == Self.codexBrokerCategoryIdentifier
    guard categoryIdentifier == Self.categoryIdentifier || isCodexBroker else {
      return nil
    }
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
      let occurredAt = boundedString(fields["occurredAt"], maximumLength: 64),
      parseIso8601Timestamp(occurredAt) != nil
    else {
      return nil
    }
    let providerSessionId = boundedString(
      fields["providerSessionId"],
      maximumLength: 256
    )
    let bridgeInstanceId = boundedString(
      fields["bridgeInstanceId"],
      maximumLength: 256
    )
    let codexSourceId = bridgeInstanceId == nil
      ? nil
      : boundedString(fields["codexSourceId"], maximumLength: 256)
    let bridgeRouteIdentity = bridgeInstanceId == nil
      ? boundedString(fields["bridgeRouteIdentity"], maximumLength: 1_024)
      : nil
    let permissionId = boundedString(
      fields[isCodexBroker ? "opaqueRequestId" : "permissionId"],
      maximumLength: 256
    )
    guard let permissionId else { return nil }
    var threadId: String?
    var turnId: String?
    var authorityGeneration: String?
    var allowedActions: String?
    if isCodexBroker {
      guard
        provider == "codex",
        boundedString(fields["actionPayloadVersion"], maximumLength: 8) == "2",
        bridgeInstanceId != nil,
        codexSourceId != nil,
        let parsedThreadId = boundedString(fields["threadId"], maximumLength: 256),
        let parsedTurnId = boundedString(fields["turnId"], maximumLength: 256),
        let parsedGeneration = boundedString(
          fields["authorityGeneration"],
          maximumLength: 64
        ),
        let parsedActions = canonicalAllowedActions(fields["allowedActions"]),
        (actionIdentifier == rejectActionIdentifier
          ? parsedActions.split(separator: ",").contains("reject")
          : parsedActions.split(separator: ",").contains("approve"))
      else {
        return nil
      }
      threadId = parsedThreadId
      turnId = parsedTurnId
      authorityGeneration = parsedGeneration
      allowedActions = parsedActions
    }
    return NotificationApprovalActionPayload(
      actionIdentifier: actionIdentifier,
      sessionId: sessionId,
      provider: provider,
      providerSessionId: providerSessionId,
      bridgeInstanceId: bridgeInstanceId,
      codexSourceId: codexSourceId,
      bridgeRouteIdentity: bridgeRouteIdentity,
      permissionId: permissionId,
      occurredAt: occurredAt,
      actionPayloadVersion: isCodexBroker ? 2 : 1,
      threadId: threadId,
      turnId: turnId,
      authorityGeneration: authorityGeneration,
      allowedActions: allowedActions
    )
  }

  private static func canonicalAllowedActions(_ value: Any?) -> String? {
    guard let raw = boundedString(value, maximumLength: 128) else { return nil }
    let allowed = Set(["approve", "approve_always", "reject", "answer"])
    let actions = raw
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard
      !actions.isEmpty,
      actions.count <= 4,
      actions.allSatisfy({ !$0.isEmpty && allowed.contains($0) })
    else {
      return nil
    }
    return Array(Set(actions)).sorted().joined(separator: ",")
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

  /// Parses ISO 8601 timestamps with or without fractional seconds.
  ///
  /// Bridge/Dart senders emit fractional seconds (JS `toISOString()`), while
  /// other senders may omit them; both shapes must be accepted.
  private static func parseIso8601Timestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
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
  static let nativeApiVersion = 2
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
        $0.bridgeInstanceId == action.bridgeInstanceId &&
        $0.codexSourceId == action.codexSourceId &&
        $0.bridgeRouteIdentity == action.bridgeRouteIdentity &&
        ($0.providerSessionId ?? $0.sessionId) ==
          (action.providerSessionId ?? action.sessionId) &&
        $0.permissionId == action.permissionId &&
        $0.actionPayloadVersion == action.actionPayloadVersion &&
        $0.threadId == action.threadId &&
        $0.turnId == action.turnId &&
        $0.authorityGeneration == action.authorityGeneration
    }
    pending.append(action)
    if pending.count > maximumPendingActions {
      pending.removeFirst(pending.count - maximumPendingActions)
    }
  }
}
