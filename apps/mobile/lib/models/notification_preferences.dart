/// User-controlled notification categories.
///
/// The values are stored locally and are also sent to compatible Bridges when
/// the FCM token is registered. New event types are opt-in by default so an
/// older mobile client never starts receiving a noisy category unexpectedly.
class NotificationPreferences {
  const NotificationPreferences({
    this.actionRequired = true,
    this.taskCompleted = true,
    this.taskFailed = true,
    this.progress = false,
    this.showWhileAppOpen = true,
  });

  static const defaults = NotificationPreferences();

  static const approvalRequiredEvent = 'approval_required';
  static const askUserQuestionEvent = 'ask_user_question';
  static const sessionCompletedEvent = 'session_completed';
  static const sessionFailedEvent = 'session_failed';
  static const sessionProgressEvent = 'session_progress';
  static const bridgeCapability = 'push_notification_preferences_v1';

  final bool actionRequired;
  final bool taskCompleted;
  final bool taskFailed;
  final bool progress;
  final bool showWhileAppOpen;

  List<String> get enabledRemoteEventTypes => [
    if (actionRequired) ...[approvalRequiredEvent, askUserQuestionEvent],
    if (taskCompleted) sessionCompletedEvent,
    if (taskFailed) sessionFailedEvent,
    if (progress) sessionProgressEvent,
  ];

  bool allowsRemoteEvent(String eventType) {
    return switch (eventType) {
      approvalRequiredEvent || askUserQuestionEvent => actionRequired,
      sessionCompletedEvent => taskCompleted,
      sessionFailedEvent => taskFailed,
      sessionProgressEvent => progress,
      // Preserve existing and future critical notification types. Their own
      // feature modules may add a dedicated preference later.
      _ => true,
    };
  }

  NotificationPreferences copyWith({
    bool? actionRequired,
    bool? taskCompleted,
    bool? taskFailed,
    bool? progress,
    bool? showWhileAppOpen,
  }) {
    return NotificationPreferences(
      actionRequired: actionRequired ?? this.actionRequired,
      taskCompleted: taskCompleted ?? this.taskCompleted,
      taskFailed: taskFailed ?? this.taskFailed,
      progress: progress ?? this.progress,
      showWhileAppOpen: showWhileAppOpen ?? this.showWhileAppOpen,
    );
  }

  Map<String, dynamic> toJson() => {
    'actionRequired': actionRequired,
    'taskCompleted': taskCompleted,
    'taskFailed': taskFailed,
    'progress': progress,
    'showWhileAppOpen': showWhileAppOpen,
  };

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      actionRequired: json['actionRequired'] as bool? ?? true,
      taskCompleted: json['taskCompleted'] as bool? ?? true,
      taskFailed: json['taskFailed'] as bool? ?? true,
      progress: json['progress'] as bool? ?? false,
      showWhileAppOpen: json['showWhileAppOpen'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is NotificationPreferences &&
        other.actionRequired == actionRequired &&
        other.taskCompleted == taskCompleted &&
        other.taskFailed == taskFailed &&
        other.progress == progress &&
        other.showWhileAppOpen == showWhileAppOpen;
  }

  @override
  int get hashCode => Object.hash(
    actionRequired,
    taskCompleted,
    taskFailed,
    progress,
    showWhileAppOpen,
  );
}
