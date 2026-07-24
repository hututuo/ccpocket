import 'package:flutter/foundation.dart';

import '../../models/messages.dart';

enum PendingSessionRequestKind { start, resume }

enum PendingSessionMatchQuality { none, legacy, exact }

@immutable
class PendingSessionFailure {
  const PendingSessionFailure(this.message);

  final SystemMessage message;

  String? get errorMessage => message.errorMessage;
}

/// Per-navigation ownership for an in-flight session start or resume.
///
/// New Bridge versions echo [requestId], so two same-project operations cannot
/// claim each other's `session_created`. Legacy Bridges omit the id; that path
/// is admitted only by [dispatchPendingSessionMessage] when exactly one active
/// binding matches the provider/project/durable-session identity.
class PendingSessionBinding extends ValueNotifier<SystemMessage?> {
  PendingSessionBinding({
    required this.kind,
    required this.requestId,
    required this.provider,
    required this.projectPath,
    required this.allowLegacyFallback,
    this.providerSessionId,
    this.onDisposed,
  }) : failure = ValueNotifier<PendingSessionFailure?>(null),
       super(null);

  final PendingSessionRequestKind kind;
  final String requestId;
  final String provider;
  final String projectPath;
  final String? providerSessionId;
  final bool allowLegacyFallback;
  final VoidCallback? onDisposed;
  final ValueNotifier<PendingSessionFailure?> failure;

  bool _disposed = false;

  PendingSessionMatchQuality match(SystemMessage message) {
    if (value != null || failure.value != null) {
      return PendingSessionMatchQuality.none;
    }
    final isCreated = message.subtype == 'session_created';
    final isFailure = switch (kind) {
      PendingSessionRequestKind.start =>
        message.subtype == 'session_start_failed',
      PendingSessionRequestKind.resume =>
        message.subtype == 'session_resume_failed',
    };
    if (!isCreated && !isFailure) return PendingSessionMatchQuality.none;

    final echoedRequestId = switch (kind) {
      PendingSessionRequestKind.start => message.startRequestId,
      PendingSessionRequestKind.resume => message.resumeRequestId,
    };
    if (echoedRequestId != null) {
      return echoedRequestId == requestId
          ? PendingSessionMatchQuality.exact
          : PendingSessionMatchQuality.none;
    }
    if (!allowLegacyFallback) return PendingSessionMatchQuality.none;
    if (!_providerMatches(message.provider)) {
      return PendingSessionMatchQuality.none;
    }

    return switch (kind) {
      PendingSessionRequestKind.start =>
        _legacyStartMatches(message)
            ? PendingSessionMatchQuality.legacy
            : PendingSessionMatchQuality.none,
      PendingSessionRequestKind.resume =>
        _legacyResumeMatches(message)
            ? PendingSessionMatchQuality.legacy
            : PendingSessionMatchQuality.none,
    };
  }

  void accept(SystemMessage message) {
    if (_disposed || value != null || failure.value != null) return;
    if (message.subtype == 'session_created') {
      value = message;
    } else {
      failure.value = PendingSessionFailure(message);
    }
  }

  bool _providerMatches(String? actual) =>
      actual == null || actual.isEmpty || actual == provider;

  bool _legacyStartMatches(SystemMessage message) {
    if (message.resumeRequestId != null ||
        message.sourceSessionId != null ||
        message.clearContext) {
      return false;
    }
    return _sameProjectPath(message.projectPath, projectPath);
  }

  bool _legacyResumeMatches(SystemMessage message) {
    if (message.startRequestId != null) return false;
    final expected = providerSessionId;
    if (expected == null || expected.isEmpty) return false;
    final identityMatches =
        message.sourceSessionId == expected ||
        message.claudeSessionId == expected;
    if (!identityMatches) return false;
    final actualProjectPath = message.projectPath;
    return actualProjectPath == null ||
        actualProjectPath.isEmpty ||
        _sameProjectPath(actualProjectPath, projectPath);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDisposed?.call();
    failure.dispose();
    super.dispose();
  }
}

/// Dispatches one Bridge system event to its unique Mobile-owned operation.
///
/// Exact request-id matches always win. A legacy uncorrelated event is accepted
/// only when one and only one binding matches, preventing two same-project
/// pending screens from binding to the first session that happens to start.
PendingSessionBinding? dispatchPendingSessionMessage(
  Iterable<PendingSessionBinding> bindings,
  SystemMessage message,
) {
  final exact = <PendingSessionBinding>[];
  final legacy = <PendingSessionBinding>[];
  for (final binding in bindings) {
    switch (binding.match(message)) {
      case PendingSessionMatchQuality.exact:
        exact.add(binding);
      case PendingSessionMatchQuality.legacy:
        legacy.add(binding);
      case PendingSessionMatchQuality.none:
        break;
    }
  }
  final selected = switch ((exact.length, legacy.length)) {
    (1, _) => exact.single,
    (0, 1) => legacy.single,
    _ => null,
  };
  selected?.accept(message);
  return selected;
}

bool _sameProjectPath(String? left, String right) {
  if (left == null || left.isEmpty) return false;

  String normalize(String value) {
    final trimmed = value.trim();
    if (trimmed == '/') return trimmed;
    return trimmed.replaceAll(RegExp(r'/+$'), '');
  }

  return normalize(left) == normalize(right);
}
