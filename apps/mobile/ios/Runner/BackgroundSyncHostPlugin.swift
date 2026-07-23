import BackgroundTasks
import Flutter
import UIKit

final class BackgroundRefreshCompletion {
  private let lock = NSLock()
  private let completion: (Bool) -> Void
  private var completed = false

  init(completion: @escaping (Bool) -> Void) {
    self.completion = completion
  }

  @discardableResult
  func finish(success: Bool) -> Bool {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return false
    }
    completed = true
    lock.unlock()
    completion(success)
    return true
  }
}

enum BackgroundRefreshAdmission: Equatable {
  case waitingForEndpoint
  case started
  case rejectedBusy
  case rejectedExpired
}

enum BackgroundRefreshPendingState: Equatable {
  case idle
  case waiting(runId: String)
  case running(runId: String)
}

struct BackgroundRefreshEndpoint {
  typealias PerformOperation =
    (_ runId: String, _ deadline: Date, _ completion: @escaping (Bool) -> Void) -> Void
  typealias ExpireOperation = (_ runId: String) -> Void

  let perform: PerformOperation
  let expire: ExpireOperation
}

/// Owns at most one delivered BGAppRefreshTask while an existing Flutter
/// runtime is registering its Dart callback. A delivered task keeps its
/// original deadline and is handed to the ready method channel exactly once.
///
/// The controller is deliberately independent of Flutter and BackgroundTasks
/// so startup-race and expiration state transitions can be unit tested. It
/// does not create a headless Flutter engine; no ready runtime means fail
/// closed at the original deadline.
final class BackgroundRefreshPendingController {
  private struct CurrentRequest {
    let runId: String
    let deadline: Date
    let finish: (Bool) -> Void
    var endpoint: BackgroundRefreshEndpoint?
  }

  private let lock = NSLock()
  private let now: () -> Date
  private var endpoint: BackgroundRefreshEndpoint?
  private var current: CurrentRequest?

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  var state: BackgroundRefreshPendingState {
    lock.lock()
    defer { lock.unlock() }
    guard let current else { return .idle }
    if current.endpoint == nil {
      return .waiting(runId: current.runId)
    }
    return .running(runId: current.runId)
  }

  /// Makes a Flutter endpoint available. A task delivered earlier is started
  /// once, unless its original deadline has already elapsed.
  func attach(endpoint newEndpoint: BackgroundRefreshEndpoint) {
    let currentTime = now()
    var requestToStart: CurrentRequest?
    var expiredRequest: CurrentRequest?

    lock.lock()
    endpoint = newEndpoint
    if var pending = current, pending.endpoint == nil {
      if pending.deadline <= currentTime {
        current = nil
        expiredRequest = pending
      } else {
        pending.endpoint = newEndpoint
        current = pending
        requestToStart = pending
      }
    }
    lock.unlock()

    expiredRequest?.finish(false)
    if let requestToStart {
      start(requestToStart)
    }
  }

  /// Invalidates a Flutter endpoint before an engine replacement. A task
  /// already running on that endpoint is failed exactly once; a task still
  /// waiting for its first endpoint remains pending for the replacement.
  func detachEndpoint() {
    var runningRequest: CurrentRequest?

    lock.lock()
    endpoint = nil
    if let active = current, active.endpoint != nil {
      current = nil
      runningRequest = active
    }
    lock.unlock()

    if let runningRequest {
      runningRequest.endpoint?.expire(runningRequest.runId)
      runningRequest.finish(false)
    }
  }

  @discardableResult
  func enqueue(
    runId: String,
    deadline: Date,
    finish: @escaping (Bool) -> Void
  ) -> BackgroundRefreshAdmission {
    let currentTime = now()
    var requestToStart: CurrentRequest?
    var admission: BackgroundRefreshAdmission

    lock.lock()
    if deadline <= currentTime {
      admission = .rejectedExpired
    } else if current != nil {
      admission = .rejectedBusy
    } else {
      let request = CurrentRequest(
        runId: runId,
        deadline: deadline,
        finish: finish,
        endpoint: endpoint
      )
      current = request
      if endpoint == nil {
        admission = .waitingForEndpoint
      } else {
        admission = .started
        requestToStart = request
      }
    }
    lock.unlock()

    if admission == .rejectedBusy || admission == .rejectedExpired {
      finish(false)
    } else if let requestToStart {
      start(requestToStart)
    }
    return admission
  }

  /// Expires only the currently matching task. A late expiration from an old
  /// task cannot finish or notify a newer task.
  @discardableResult
  func expire(runId: String) -> Bool {
    var expiredRequest: CurrentRequest?

    lock.lock()
    if let active = current, active.runId == runId {
      current = nil
      expiredRequest = active
    }
    lock.unlock()

    guard let expiredRequest else { return false }
    expiredRequest.endpoint?.expire(runId)
    expiredRequest.finish(false)
    return true
  }

  private func start(_ request: CurrentRequest) {
    guard let endpoint = request.endpoint else { return }
    endpoint.perform(request.runId, request.deadline) { [weak self] success in
      self?.complete(runId: request.runId, success: success)
    }
  }

  private func complete(runId: String, success: Bool) {
    var completedRequest: CurrentRequest?

    lock.lock()
    if let active = current, active.runId == runId {
      current = nil
      completedRequest = active
    }
    lock.unlock()

    completedRequest?.finish(success)
  }
}

final class BackgroundContinuationController {
  typealias BeginOperation =
    (_ name: String, _ expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
  typealias EndOperation = (UIBackgroundTaskIdentifier) -> Void

  private let beginOperation: BeginOperation
  private let endOperation: EndOperation
  private var identifier = UIBackgroundTaskIdentifier.invalid
  private(set) var activeGeneration: Int?

  init(
    begin: @escaping BeginOperation,
    end: @escaping EndOperation
  ) {
    beginOperation = begin
    endOperation = end
  }

  @discardableResult
  func begin(
    generation: Int,
    reason: String,
    onExpiration: @escaping (Int) -> Void
  ) -> Bool {
    guard generation > 0 else { return false }
    if activeGeneration == generation, identifier != .invalid {
      return true
    }
    endCurrent()
    let taskName = "CCPocketBackgroundSync:\(reason)"
    identifier = beginOperation(taskName) { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.activeGeneration == generation else { return }
        self.endCurrent()
        onExpiration(generation)
      }
    }
    guard identifier != .invalid else {
      activeGeneration = nil
      return false
    }
    activeGeneration = generation
    return true
  }

  @discardableResult
  func end(generation: Int) -> Bool {
    guard activeGeneration == generation else { return false }
    endCurrent()
    return true
  }

  func endCurrent() {
    let current = identifier
    identifier = .invalid
    activeGeneration = nil
    if current != .invalid {
      endOperation(current)
    }
  }
}

final class BackgroundSyncHostPlugin: NSObject, FlutterPlugin {
  static let channelName = "ccpocket/background_sync"
  static let refreshTaskIdentifier = "com.k9i.ccpocket.background-refresh"
  static let minimumRefreshDelay: TimeInterval = 15 * 60
  static let refreshExecutionBudget: TimeInterval = 25

  private static var channel: FlutterMethodChannel?
  private static var schedulerRegistrationAttempted = false
  private static var schedulerRegistered = false
  private static var refreshRequestPending = false
  private static let refreshController = BackgroundRefreshPendingController()
  private static var registrationGeneration = 0
  private static var refreshEndpoint: BackgroundRefreshEndpoint?
  private static weak var activePlugin: BackgroundSyncHostPlugin?

  private let registrationGeneration: Int
  private let continuation = BackgroundContinuationController(
    begin: { name, expiration in
      UIApplication.shared.beginBackgroundTask(
        withName: name,
        expirationHandler: expiration
      )
    },
    end: { identifier in
      UIApplication.shared.endBackgroundTask(identifier)
    }
  )

  private init(registrationGeneration: Int) {
    self.registrationGeneration = registrationGeneration
    super.init()
  }

  @discardableResult
  static func registerBackgroundRefreshTask() -> Bool {
    if schedulerRegistrationAttempted { return schedulerRegistered }
    schedulerRegistrationAttempted = true
    schedulerRegistered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: refreshTaskIdentifier,
      using: nil
    ) { task in
      handleBackgroundRefreshTask(task)
    }
    return schedulerRegistered
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrationGeneration += 1
    let plugin = BackgroundSyncHostPlugin(
      registrationGeneration: registrationGeneration
    )
    activePlugin?.continuation.endCurrent()
    refreshController.detachEndpoint()
    activePlugin = plugin
    channel = methodChannel
    registrar.addMethodCallDelegate(plugin, channel: methodChannel)
    refreshEndpoint = BackgroundRefreshEndpoint(
      perform: { runId, deadline, completion in
        runOnMain {
          methodChannel.invokeMethod(
            "performRefresh",
            arguments: [
              "runId": runId,
              "deadlineEpochMs": Int(deadline.timeIntervalSince1970 * 1000),
            ]
          ) { value in
            runOnMain {
              completion((value as? NSNumber)?.boolValue ?? false)
            }
          }
        }
      },
      expire: { runId in
        runOnMain {
          methodChannel.invokeMethod(
            "expireRefresh",
            arguments: ["runId": runId]
          )
        }
      }
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setDartReady":
      guard
        registrationGeneration == Self.registrationGeneration,
        let endpoint = Self.refreshEndpoint
      else {
        result(Self.rejected("stale_flutter_engine"))
        return
      }
      Self.runOnMain {
        Self.refreshController.attach(endpoint: endpoint)
      }
      result(Self.accepted())
    case "getStatus":
      result(Self.status(activeGeneration: continuation.activeGeneration))
    case "beginContinuation":
      guard
        let arguments = call.arguments as? [String: Any],
        let generation = (arguments["generation"] as? NSNumber)?.intValue,
        let reason = arguments["reason"] as? String,
        generation > 0,
        !reason.isEmpty,
        reason.count <= 128
      else {
        result(Self.rejected("invalid_arguments"))
        return
      }
      let accepted = continuation.begin(
        generation: generation,
        reason: reason
      ) { expiredGeneration in
        Self.channel?.invokeMethod(
          "continuationExpired",
          arguments: ["generation": expiredGeneration]
        )
      }
      result(accepted ? Self.accepted() : Self.rejected("unavailable"))
    case "endContinuation":
      guard
        let arguments = call.arguments as? [String: Any],
        let generation = (arguments["generation"] as? NSNumber)?.intValue,
        generation > 0
      else {
        result(Self.rejected("invalid_arguments"))
        return
      }
      // A stale end is intentionally a successful no-op. It must never close a
      // newer continuation generation.
      _ = continuation.end(generation: generation)
      result(Self.accepted())
    case "scheduleRefresh":
      guard
        let arguments = call.arguments as? [String: Any],
        let rawDelay = (arguments["earliestBeginSeconds"] as? NSNumber)?
          .doubleValue,
        rawDelay.isFinite,
        rawDelay >= 0
      else {
        result(Self.rejected("invalid_arguments"))
        return
      }
      result(Self.scheduleRefresh(earliestBeginSeconds: rawDelay))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func status(activeGeneration: Int?) -> [String: Any] {
    var value: [String: Any] = [
      "accepted": true,
      "schedulerRegistered": schedulerRegistered,
      "refreshRequestPending": refreshRequestPending,
      "backgroundRefreshStatus": UIApplication.shared.backgroundRefreshStatus.rawValue,
    ]
    if let activeGeneration {
      value["activeContinuationGeneration"] = activeGeneration
    }
    return value
  }

  static func scheduleRefresh(
    earliestBeginSeconds: TimeInterval = minimumRefreshDelay
  ) -> [String: Any] {
    guard schedulerRegistered else {
      return rejected("scheduler_not_registered")
    }
    if refreshRequestPending { return accepted() }
    let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
    request.earliestBeginDate = Date(
      timeIntervalSinceNow: max(minimumRefreshDelay, earliestBeginSeconds)
    )
    do {
      try BGTaskScheduler.shared.submit(request)
      refreshRequestPending = true
      return accepted()
    } catch {
      return rejected("schedule_failed", details: error.localizedDescription)
    }
  }

  private static func handleBackgroundRefreshTask(_ task: BGTask) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async {
        handleBackgroundRefreshTask(task)
      }
      return
    }

    refreshRequestPending = false
    // Deliberately do not reschedule here. A Shorebird rollback can leave this
    // native host paired with older Dart code that has no readiness handshake;
    // only a ready Dart coordinator may opt into the next refresh request.

    guard let refreshTask = task as? BGAppRefreshTask else {
      task.setTaskCompleted(success: false)
      return
    }
    let runId = UUID().uuidString
    let deadline = Date(timeIntervalSinceNow: refreshExecutionBudget)
    var timeout: DispatchWorkItem?
    let completion = BackgroundRefreshCompletion { success in
      timeout?.cancel()
      refreshTask.expirationHandler = nil
      refreshTask.setTaskCompleted(success: success)
    }
    let timeoutWorkItem = DispatchWorkItem {
      _ = refreshController.expire(runId: runId)
    }
    timeout = timeoutWorkItem
    refreshTask.expirationHandler = {
      runOnMain {
        _ = refreshController.expire(runId: runId)
      }
    }

    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, deadline.timeIntervalSinceNow),
      execute: timeoutWorkItem
    )
    _ = refreshController.enqueue(
      runId: runId,
      deadline: deadline,
      finish: { success in
        _ = completion.finish(success: success)
      }
    )
  }

  private static func runOnMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }

  static func accepted() -> [String: Any] {
    ["accepted": true]
  }

  static func rejected(
    _ reason: String,
    details: String? = nil
  ) -> [String: Any] {
    var value: [String: Any] = [
      "accepted": false,
      "reason": reason,
    ]
    if let details { value["details"] = details }
    return value
  }
}
