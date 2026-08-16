import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_service.dart';
import '../../../services/performance_probe_extension.dart';
import '../../../utils/artifact_link_matcher.dart';
import '../../../widgets/bubbles/assistant_bubble.dart';
import '../../../widgets/bubbles/guardian_approval_notice.dart';
import '../../../widgets/bubbles/todo_write_widget.dart';
import '../../../widgets/bubbles/tool_result_bubble.dart';
import '../../../widgets/chat_selection_actions.dart';
import '../../../widgets/chat_message_timestamp.dart';
import '../../../widgets/message_bubble.dart';
import '../../artifact_preview/artifact_preview_entry.dart';
import '../../generated_image_preview/generated_image_preview_mapper.dart';
import '../../generated_image_preview/generated_image_preview_item.dart';
import '../../generated_image_preview/generated_image_response_grouping.dart';
import '../../generated_image_preview/widgets/generated_image_chat_group.dart';
import '../../file_peek/file_peek_sheet.dart';
import '../../message_images/message_images_screen.dart';
import '../state/chat_session_cubit.dart';
import '../state/chat_session_state.dart';
import '../state/streaming_state.dart';
import '../state/streaming_state_cubit.dart';
import 'chat_intermediate_process_group.dart';
import 'maintain_reading_position_physics.dart';
import 'chat_process_disclosure.dart';
import 'chat_process_layout.dart';
import 'reading_position_auto_scroll_controller.dart';

String? resolveChatFileRoot({String? worktreePath, String? projectPath}) {
  final worktree = worktreePath?.trim();
  if (worktree != null && worktree.isNotEmpty) return worktree;
  final project = projectPath?.trim();
  return project == null || project.isEmpty ? null : project;
}

@visibleForTesting
bool shouldPreferUnifiedArtifactPreview(
  ArtifactRef artifact, [
  TargetPlatform? platform,
]) =>
    artifact.isSource &&
    artifact.line == null &&
    supportsEmbeddedArtifactPreview(platform);

@visibleForTesting
bool shouldShowForkForAssistant(
  List<ChatEntry> entries,
  int entryIndex, {
  bool transcriptTailComplete = false,
}) {
  if (entryIndex < 0 || entryIndex >= entries.length) return false;
  final entry = entries[entryIndex];
  if (entry is! ServerChatEntry || entry.message is! AssistantServerMessage) {
    return false;
  }
  final assistant = entry.message as AssistantServerMessage;
  final hasVisibleReply = assistant.message.content.any(
    (content) => content is TextContent && content.text.trim().isNotEmpty,
  );
  if (!hasVisibleReply) return false;

  var assistantTurnId = chatEntryHistoryTurnId(entry);
  var hasTerminalResult = false;
  for (var i = entryIndex + 1; i < entries.length; i++) {
    final next = entries[i];
    final nextTurnId = chatEntryHistoryTurnId(next);
    // Desktop/app-server history may omit the synthetic ResultMessage that the
    // live Bridge stream emits. A following user turn still proves that this
    // was the final assistant reply only when it is a different provider turn.
    // A steer/user item with the same explicit turn id belongs to the active
    // turn and must not turn progress into a fork point.
    if (next is UserChatEntry &&
        (assistantTurnId == null ||
            nextTurnId == null ||
            nextTurnId != assistantTurnId)) {
      return true;
    }
    if (assistantTurnId != null &&
        nextTurnId != null &&
        nextTurnId != assistantTurnId) {
      return true;
    }
    assistantTurnId ??= nextTurnId;
    if (next is ServerChatEntry) {
      final message = next.message;
      // Fork is turn-granular: a later visible assistant update means this
      // block was progress inside the same turn, not an item-level branch
      // point. Tool-only assistant envelopes do not replace the visible reply.
      if (message is AssistantServerMessage &&
          message.message.content.any(
            (content) =>
                content is TextContent && content.text.trim().isNotEmpty,
          )) {
        return false;
      }
      if (message is ResultMessage) hasTerminalResult = true;
    }
  }
  return hasTerminalResult || transcriptTailComplete;
}

String chatMessageEntryStableKey(ChatEntry entry) {
  return switch (entry) {
    ServerChatEntry(:final message) => switch (message) {
      ToolResultMessage() =>
        'tool:${chatToolResultEntryStableIdentity(message, entry.timestamp)}',
      AssistantServerMessage() =>
        'assistant:${chatAssistantEntryStableIdentity(message, entry.timestamp)}',
      PermissionRequestMessage(:final toolUseId) => 'permission:$toolUseId',
      ToolUseSummaryMessage(:final precedingToolUseIds) =>
        precedingToolUseIds.isNotEmpty
            ? 'tool_summary:${precedingToolUseIds.first}'
            : 'tool_summary:${entry.timestamp.microsecondsSinceEpoch}',
      _ => '${message.runtimeType}:${entry.timestamp.microsecondsSinceEpoch}',
    },
    UserChatEntry() => 'user:${chatUserEntryStableIdentity(entry)}',
    StreamingChatEntry() => 'streaming',
  };
}

/// Read-only handle for capturing the exact transcript projection currently
/// owned by [ChatMessageList]. Full payload serialization happens only after
/// an explicit report request. Ordinary builds contribute only a bounded,
/// payload-free temporal digest so a recent visible flicker can be recovered.
class ChatMessageListDiagnosticController {
  _ChatMessageListDiagnosticSource? _source;
  final Stopwatch _traceClock = Stopwatch()..start();
  final List<Map<String, Object?>> _temporalTrace = [];
  StreamSubscription<StreamingState>? _streamingSubscription;
  Object? _streamingOwner;
  String? _targetSessionId;
  String? _lastTemporalRevision;
  int _temporalSequence = 0;
  int _buildSerial = 0;
  int _frameSerial = 0;
  int _rawTemporalSampleCount = 0;
  int _droppedTemporalSampleCount = 0;
  bool _postFrameCaptureScheduled = false;

  Map<String, Object?> capture({int maximumPayloadBytes = 4 * 1024 * 1024}) =>
      _source?.capture(maximumPayloadBytes: maximumPayloadBytes) ??
      const <String, Object?>{
        'available': false,
        'reason': 'chatMessageListNotAttached',
      };

  /// Records a short post-click observation while retaining the last ten
  /// seconds of in-memory, payload-free post-frame changes. Nothing is written
  /// or uploaded until the user explicitly requests a diagnostic report.
  Future<Map<String, Object?>> observeTemporalChanges({
    Duration duration = const Duration(seconds: 3),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final observationStartedAt = DateTime.now().toUtc();
    final observationStartedElapsedUs = _traceClock.elapsedMicroseconds;
    final rawSamplesBeforeObservation = _rawTemporalSampleCount;
    final droppedSamplesBeforeObservation = _droppedTemporalSampleCount;
    _recordTemporal(trigger: 'observationStart', force: true);
    var heartbeat = 0;
    final timer = Timer.periodic(interval, (_) {
      heartbeat += 1;
      _recordTemporal(trigger: 'timer', force: heartbeat % 5 == 0);
    });
    try {
      await Future<void>.delayed(duration);
    } finally {
      timer.cancel();
    }
    _recordTemporal(trigger: 'observationEnd', force: true);
    final lowerBound =
        observationStartedElapsedUs -
        const Duration(seconds: 10).inMicroseconds;
    final samples = <Map<String, Object?>>[
      for (final sample in _temporalTrace)
        if ((sample['monotonicElapsedUs'] as int? ?? 0) >= lowerBound)
          Map<String, Object?>.from(sample),
    ];
    final preTriggerSamples = <Map<String, Object?>>[];
    final observationSamples = <Map<String, Object?>>[];
    for (final sample in samples) {
      final elapsed = sample['monotonicElapsedUs'] as int? ?? 0;
      if (elapsed < observationStartedElapsedUs) {
        preTriggerSamples.add(sample);
      } else {
        observationSamples.add(sample);
      }
    }
    int countRevisionChanges(List<Map<String, Object?>> values) {
      var changes = 0;
      String? previousRevision;
      for (final value in values) {
        final revision = value['revision'] as String?;
        if (previousRevision != null && revision != previousRevision) {
          changes += 1;
        }
        previousRevision = revision;
      }
      return changes;
    }

    final observationChangeCount = countRevisionChanges(observationSamples);
    var preTriggerChangeCount = countRevisionChanges(preTriggerSamples);
    if (preTriggerSamples.isNotEmpty &&
        observationSamples.isNotEmpty &&
        preTriggerSamples.last['revision'] !=
            observationSamples.first['revision']) {
      preTriggerChangeCount += 1;
    }
    final totalObservedChangeCount =
        observationChangeCount + preTriggerChangeCount;
    final firstPreTriggerElapsed = preTriggerSamples.isEmpty
        ? observationStartedElapsedUs
        : preTriggerSamples.first['monotonicElapsedUs'] as int? ??
              observationStartedElapsedUs;
    final projectionCounts = <int>[
      for (final sample in samples)
        if (sample['projectionEntryCount'] case final int count) count,
    ];
    return <String, Object?>{
      'observationStartedAt': observationStartedAt.toIso8601String(),
      'observationDurationMs': duration.inMilliseconds,
      'sampleIntervalMs': interval.inMilliseconds,
      'preTriggerCoverageMs':
          (observationStartedElapsedUs - firstPreTriggerElapsed) ~/ 1000,
      'rawSampleCountDuringObservation':
          _rawTemporalSampleCount - rawSamplesBeforeObservation,
      'storedSampleCountDuringObservation': observationSamples.length,
      'droppedSampleCountDuringObservation':
          _droppedTemporalSampleCount - droppedSamplesBeforeObservation,
      'storedSampleCount': samples.length,
      'observedChangeCount': totalObservedChangeCount,
      'postTriggerObservedChangeCount': observationChangeCount,
      'preTriggerObservedChangeCount': preTriggerChangeCount,
      'noObservedChanges': totalObservedChangeCount == 0,
      'overflowedDuringObservation':
          _droppedTemporalSampleCount > droppedSamplesBeforeObservation,
      if (projectionCounts.isNotEmpty) ...<String, Object?>{
        'minimumProjectionEntryCount': projectionCounts.reduce(math.min),
        'maximumProjectionEntryCount': projectionCounts.reduce(math.max),
      },
      'samples': samples,
    };
  }

  void _attach(_ChatMessageListDiagnosticSource source) {
    if (_targetSessionId != null && _targetSessionId != source.sessionId) {
      _temporalTrace.clear();
      _lastTemporalRevision = null;
      _temporalSequence = 0;
      _buildSerial = 0;
      _frameSerial = 0;
      _rawTemporalSampleCount = 0;
      _droppedTemporalSampleCount = 0;
    }
    _targetSessionId = source.sessionId;
    _source = source;
    _buildSerial += 1;
    if (!identical(_streamingOwner, source.owner)) {
      unawaited(_streamingSubscription?.cancel());
      _streamingOwner = source.owner;
      _streamingSubscription = source.streamingCubit.stream.listen((_) {
        _schedulePostFrameTemporalCapture('streaming');
      });
    }
    _schedulePostFrameTemporalCapture('postFrame');
  }

  void _detach(Object owner) {
    if (!identical(_source?.owner, owner)) return;
    _recordTemporal(trigger: 'detach', force: true);
    _source = null;
    _streamingOwner = null;
    unawaited(_streamingSubscription?.cancel());
    _streamingSubscription = null;
  }

  void _schedulePostFrameTemporalCapture(String trigger) {
    if (_postFrameCaptureScheduled) return;
    _postFrameCaptureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _postFrameCaptureScheduled = false;
      _frameSerial += 1;
      _recordTemporal(trigger: trigger);
    });
  }

  void _recordTemporal({required String trigger, bool force = false}) {
    _rawTemporalSampleCount += 1;
    final summary =
        _source?.temporalSummary(
          buildSerial: _buildSerial,
          frameSerial: _frameSerial,
        ) ??
        const <String, Object?>{
          'available': false,
          'reason': 'chatMessageListNotAttached',
        };
    final revisionInput = Map<String, Object?>.from(summary)
      ..remove('buildSerial')
      ..remove('frameSerial');
    final revision = sha256
        .convert(utf8.encode(jsonEncode(revisionInput)))
        .toString();
    if (!force && revision == _lastTemporalRevision) return;
    _lastTemporalRevision = revision;
    _temporalTrace.add(<String, Object?>{
      'seq': ++_temporalSequence,
      'wallAt': DateTime.now().toUtc().toIso8601String(),
      'monotonicElapsedUs': _traceClock.elapsedMicroseconds,
      'trigger': trigger,
      'revision': revision,
      ...summary,
    });
    if (_temporalTrace.length > 96) {
      final removed = _temporalTrace.length - 96;
      _temporalTrace.removeRange(0, removed);
      _droppedTemporalSampleCount += removed;
    }
  }
}

class _ChatMessageListDiagnosticSource {
  _ChatMessageListDiagnosticSource({
    required this.owner,
    required this.sessionId,
    required this.entries,
    required this.layout,
    required this.chatState,
    required this.paging,
    required this.historyBrowsing,
    required this.latestTurnIsActive,
    required this.hasStreaming,
    required this.streamingCubit,
    required this.scrollController,
    required this.expandedProcessSegments,
    required this.expandedIntermediateTurns,
    required this.expandedCurrentProgress,
    required this.imageItemsByAnchor,
    required this.imageGroupMemberIndices,
  });

  final Object owner;
  final String sessionId;
  final List<ChatEntry> entries;
  final ChatProcessLayout layout;
  final ChatSessionState chatState;
  final LocalHistoryPagingState paging;
  final bool historyBrowsing;
  final bool latestTurnIsActive;
  final bool hasStreaming;
  final StreamingStateCubit streamingCubit;
  final AutoScrollController scrollController;
  final Set<String> expandedProcessSegments;
  final Set<String> expandedIntermediateTurns;
  final Set<String> expandedCurrentProgress;
  final Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor;
  final Set<int> imageGroupMemberIndices;
  String? _cachedTemporalTailContentDigest;

  Map<String, Object?> capture({required int maximumPayloadBytes}) {
    const maximumStructuralEntries = 1024;
    final payloads = <int, Map<String, Object?>>{};
    final payloadRevisions = <int, String>{};
    var remainingPayloadBytes = maximumPayloadBytes;
    var omittedPayloadCount = 0;
    // Preserve the newest payloads first because the report is intended to
    // diagnose a stale or incomplete live tail. Every entry still keeps its
    // structural identity below even when an old, large body is omitted.
    final firstCapturedIndex = entries.length > maximumStructuralEntries
        ? entries.length - maximumStructuralEntries
        : 0;
    for (var index = entries.length - 1; index >= firstCapturedIndex; index--) {
      if (remainingPayloadBytes <= 0) {
        omittedPayloadCount += index - firstCapturedIndex + 1;
        break;
      }
      final payload = Map<String, Object?>.from(
        _boundDiagnosticValue(_diagnosticChatEntry(entries[index]))! as Map,
      );
      final encoded = utf8.encode(jsonEncode(payload));
      final encodedBytes = encoded.length;
      if (encodedBytes <= remainingPayloadBytes) {
        payloads[index] = payload;
        payloadRevisions[index] = sha256.convert(encoded).toString();
        remainingPayloadBytes -= encodedBytes;
      } else {
        // The capture is newest-first. Stop once the next bounded payload no
        // longer fits instead of serializing every older body on the UI
        // isolate after the report budget is already exhausted.
        omittedPayloadCount += index - firstCapturedIndex + 1;
        break;
      }
    }
    final entryDiagnostics = <Map<String, Object?>>[];
    final chronologicalKeys = <String>[];
    final visibleTopLevelKeys = <String>[];
    for (var index = firstCapturedIndex; index < entries.length; index++) {
      final entry = entries[index];
      final stableKey = chatMessageEntryStableKey(entry);
      chronologicalKeys.add(stableKey);
      final segment = layout.segmentForEntry(index);
      final turn = layout.turnForEntry(index);
      final role = _diagnosticRenderRole(
        index: index,
        segment: segment,
        turn: turn,
        hasStreaming: hasStreaming,
        imageItemsByAnchor: imageItemsByAnchor,
        imageGroupMemberIndices: imageGroupMemberIndices,
      );
      if (role.$2) visibleTopLevelKeys.add(stableKey);
      entryDiagnostics.add(<String, Object?>{
        'index': index,
        'stableKey': stableKey,
        'historyTurnId': chatEntryHistoryTurnId(entry),
        'timestamp': entry.timestamp.toUtc().toIso8601String(),
        'timestampIsAuthoritative': entry.timestampIsAuthoritative,
        'renderRole': role.$1,
        'visibleTopLevel': role.$2,
        'turnKey': turn?.key,
        'segmentKey': segment?.key,
        'payloadRevision': payloadRevisions[index],
        'payload':
            payloads[index] ??
            const <String, Object?>{
              'kind': 'omitted',
              'reason': 'diagnostic_payload_budget',
            },
      });
    }
    final streaming = streamingCubit.state;
    final tailContentRevision = _contentAwareTailDigest(
      maximumContentEntries: 16,
      maximumStringCharacters: 2048,
    );
    final identityBytes = utf8.encode(
      jsonEncode(<String, Object?>{
        'entries': [
          for (final entry in entryDiagnostics)
            <String, Object?>{
              'stableKey': entry['stableKey'],
              'renderRole': entry['renderRole'],
              'visibleTopLevel': entry['visibleTopLevel'],
              'turnKey': entry['turnKey'],
              'segmentKey': entry['segmentKey'],
              'payloadRevision': entry['payloadRevision'],
            },
        ],
        'tailContentRevision': tailContentRevision,
        'expandedProcessSegments': expandedProcessSegments.toList()..sort(),
        'expandedIntermediateTurns': expandedIntermediateTurns.toList()..sort(),
        'expandedCurrentProgress': expandedCurrentProgress.toList()..sort(),
        'chatStatus': chatState.status.name,
        'historyBrowsing': historyBrowsing,
        'latestTurnIsActive': latestTurnIsActive,
        'hasStreaming': hasStreaming,
        'streaming': <String, Object?>{
          'isStreaming': streaming.isStreaming,
          'text': _diagnosticTextRevision(streaming.text),
          'thinking': _diagnosticTextRevision(streaming.thinking),
        },
        'paging': <String, Object?>{
          'enabled': paging.enabled,
          'hasMore': paging.hasMore,
          'hasLater': paging.hasLater,
          'loading': paging.loading,
          'loadingLater': paging.loadingLater,
          'error': paging.error?.toString(),
          'laterError': paging.laterError?.toString(),
        },
      }),
    );
    final position = scrollController.hasClients
        ? scrollController.position
        : null;
    return <String, Object?>{
      'available': true,
      'presentationRevision': sha256.convert(identityBytes).toString(),
      'entryCount': entries.length,
      'capturedStructuralEntryCount': entryDiagnostics.length,
      'omittedStructuralEntryCount': firstCapturedIndex,
      'oldestOmittedStableKey': firstCapturedIndex == 0
          ? null
          : chatMessageEntryStableKey(entries.first),
      'payloadBudgetBytes': maximumPayloadBytes,
      'payloadBytesUsed': maximumPayloadBytes - remainingPayloadBytes,
      'omittedPayloadCount': omittedPayloadCount,
      'chronologicalStableKeys': chronologicalKeys,
      'visibleTopLevelStableKeys': visibleTopLevelKeys,
      'tailContentRevision': tailContentRevision,
      'entries': entryDiagnostics,
      'layout': <String, Object?>{
        'latestTurnKey': layout.latestTurnKey,
        'latestTurn': _diagnosticTurn(layout.latestTurn),
        'turnKeyAliases': Map<String, String>.from(layout.turnKeyAliases),
        'expandedProcessSegments': expandedProcessSegments.toList()..sort(),
        'expandedIntermediateTurns': expandedIntermediateTurns.toList()..sort(),
        'expandedCurrentProgress': expandedCurrentProgress.toList()..sort(),
      },
      'selection': <String, Object?>{
        'historyBrowsing': historyBrowsing,
        'latestTurnIsActive': latestTurnIsActive,
        'hasStreaming': hasStreaming,
      },
      'streaming': <String, Object?>{
        'isStreaming': streaming.isStreaming,
        'text': _boundedDiagnosticText(streaming.text),
        'thinking': _boundedDiagnosticText(streaming.thinking),
      },
      'paging': <String, Object?>{
        'enabled': paging.enabled,
        'hasMore': paging.hasMore,
        'hasLater': paging.hasLater,
        'loading': paging.loading,
        'loadingLater': paging.loadingLater,
        'error': paging.error?.toString(),
        'laterError': paging.laterError?.toString(),
      },
      'scroll': <String, Object?>{
        'attached': position != null,
        if (position != null) ...<String, Object?>{
          'pixels': position.pixels,
          'minScrollExtent': position.minScrollExtent,
          'maxScrollExtent': position.maxScrollExtent,
          'viewportDimension': position.viewportDimension,
        },
      },
      'chatStatus': chatState.status.name,
    };
  }

  Map<String, Object?> temporalSummary({
    required int buildSerial,
    required int frameSerial,
  }) {
    const maximumTailEntries = 96;
    final firstIndex = entries.length > maximumTailEntries
        ? entries.length - maximumTailEntries
        : 0;
    final tailKeys = <String>[];
    final visibleKeys = <String>[];
    final renderRoleCounts = <String, int>{};
    for (var index = firstIndex; index < entries.length; index++) {
      final stableKey = chatMessageEntryStableKey(entries[index]);
      tailKeys.add(stableKey);
      final role = _diagnosticRenderRole(
        index: index,
        segment: layout.segmentForEntry(index),
        turn: layout.turnForEntry(index),
        hasStreaming: hasStreaming,
        imageItemsByAnchor: imageItemsByAnchor,
        imageGroupMemberIndices: imageGroupMemberIndices,
      );
      renderRoleCounts.update(role.$1, (value) => value + 1, ifAbsent: () => 1);
      if (role.$2) visibleKeys.add(stableKey);
    }
    final streaming = streamingCubit.state;
    final position = scrollController.hasClients
        ? scrollController.position
        : null;
    return <String, Object?>{
      'available': true,
      'mounted': true,
      'buildSerial': buildSerial,
      'frameSerial': frameSerial,
      'surfaceMode': historyBrowsing ? 'history' : 'latest',
      'stateEntryCount': chatState.entries.length,
      'projectionEntryCount': entries.length,
      'tailStableKeys': tailKeys,
      'tailStableKeyDigest': sha256
          .convert(utf8.encode(jsonEncode(tailKeys)))
          .toString(),
      'tailContentDigest': _cachedTemporalTailContentDigest ??=
          _contentAwareTailDigest(
            maximumContentEntries: 4,
            maximumStringCharacters: 512,
          ),
      'visibleTopLevelCount': visibleKeys.length,
      'visibleTopLevelDigest': sha256
          .convert(utf8.encode(jsonEncode(visibleKeys)))
          .toString(),
      'renderRoleCounts': renderRoleCounts,
      'latestTurnKey': layout.latestTurnKey,
      'historyBrowsing': historyBrowsing,
      'latestTurnIsActive': latestTurnIsActive,
      'chatStatus': chatState.status.name,
      'expandedProcessSegments': expandedProcessSegments.toList()..sort(),
      'expandedIntermediateTurns': expandedIntermediateTurns.toList()..sort(),
      'expandedCurrentProgress': expandedCurrentProgress.toList()..sort(),
      'streaming': <String, Object?>{
        'isStreaming': streaming.isStreaming,
        'text': _diagnosticTextRevision(streaming.text),
        'thinking': _diagnosticTextRevision(streaming.thinking),
      },
      'paging': <String, Object?>{
        'enabled': paging.enabled,
        'hasMore': paging.hasMore,
        'hasLater': paging.hasLater,
        'loading': paging.loading,
        'loadingLater': paging.loadingLater,
        'error': paging.error?.toString(),
        'laterError': paging.laterError?.toString(),
      },
      'scroll': <String, Object?>{
        'attached': position != null,
        if (position != null) ...<String, Object?>{
          'pixels': position.pixels,
          'minScrollExtent': position.minScrollExtent,
          'maxScrollExtent': position.maxScrollExtent,
          'viewportDimension': position.viewportDimension,
        },
      },
    };
  }

  String _contentAwareTailDigest({
    required int maximumContentEntries,
    required int maximumStringCharacters,
  }) {
    final contentStart = entries.length > maximumContentEntries
        ? entries.length - maximumContentEntries
        : 0;
    final contentDigestInput = <Object?>[
      for (var index = contentStart; index < entries.length; index++)
        <String, Object?>{
          'stableKey': chatMessageEntryStableKey(entries[index]),
          'payload': _boundDiagnosticValue(
            _diagnosticChatEntry(entries[index]),
            maximumStringCharacters: maximumStringCharacters,
          ),
        },
    ];
    return sha256
        .convert(utf8.encode(jsonEncode(contentDigestInput)))
        .toString();
  }
}

String _boundedDiagnosticText(String value, {int maximumCharacters = 65536}) {
  if (value.length <= maximumCharacters) return value;
  return '${value.substring(value.length - maximumCharacters)}'
      '\n[DIAGNOSTIC KEPT LAST $maximumCharacters OF ${value.length} CHARS]';
}

Map<String, Object?> _diagnosticTextRevision(String value) {
  const edgeCharacters = 32768;
  final sampled = value.length <= edgeCharacters * 2
      ? value
      : '${value.substring(0, edgeCharacters)}'
            '${value.substring(value.length - edgeCharacters)}';
  return <String, Object?>{
    'length': value.length,
    'sampledCharacters': sampled.length,
    'edgeSha256': sha256.convert(utf8.encode(sampled)).toString(),
  };
}

Object? _boundDiagnosticValue(
  Object? value, {
  int depth = 0,
  int maximumStringCharacters = 65536,
}) {
  if (depth > 32) return '[DIAGNOSTIC_DEPTH_LIMIT]';
  if (value is String) {
    return _boundedDiagnosticText(
      value,
      maximumCharacters: maximumStringCharacters,
    );
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries.take(512))
        entry.key.toString(): _boundDiagnosticValue(
          entry.value,
          depth: depth + 1,
          maximumStringCharacters: maximumStringCharacters,
        ),
      if (value.length > 512)
        'ccpocketDiagnosticOmittedFields': value.length - 512,
    };
  }
  if (value is Iterable) {
    final sourceLength = value.length;
    final bounded = <Object?>[
      for (final item in value.take(512))
        _boundDiagnosticValue(
          item,
          depth: depth + 1,
          maximumStringCharacters: maximumStringCharacters,
        ),
    ];
    if (sourceLength > 512) {
      bounded.add(<String, Object?>{
        'ccpocketDiagnosticOmittedItems': sourceLength - 512,
      });
    }
    return bounded;
  }
  return value;
}

(String, bool) _diagnosticRenderRole({
  required int index,
  required ChatProcessSegmentLayout? segment,
  required ChatProcessTurnLayout? turn,
  required bool hasStreaming,
  required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
  required Set<int> imageGroupMemberIndices,
}) {
  if (turn?.isPlanUpdateEntry(index) == true) {
    if (turn!.latestPlanUpdateInput == null) {
      return ('hiddenPlanUpdateWithoutInput', false);
    }
    return turn.showsPlanUpdateAt(index)
        ? ('planUpdate', true)
        : ('hiddenPlanUpdateMember', false);
  }
  if (turn?.isIntermediateEntry(index) == true) {
    return turn!.showsIntermediateSummaryAt(index)
        ? ('intermediateSummary', true)
        : ('foldedIntermediateMember', false);
  }
  final current = turn?.currentSegment;
  if (!hasStreaming && current?.containsEntry(index) == true) {
    return current!.showsSummaryAt(index)
        ? ('currentProgressSummary', true)
        : ('currentProgressMember', false);
  }
  if (segment != null) {
    return segment.showsSummaryAt(index)
        ? ('processSummary', true)
        : ('processMember', false);
  }
  if (imageItemsByAnchor.containsKey(index)) {
    return ('generatedImageGroup', true);
  }
  if (imageGroupMemberIndices.contains(index)) {
    return ('hiddenGeneratedImageMember', false);
  }
  return ('transcript', true);
}

Map<String, Object?>? _diagnosticTurn(ChatProcessTurnLayout? turn) {
  if (turn == null) return null;
  return <String, Object?>{
    'key': turn.key,
    'isActive': turn.isActive,
    'hasTransientCurrentOutput': turn.hasTransientCurrentOutput,
    'intermediateDetailCount': turn.intermediateDetailCount,
    'intermediateOutputCount': turn.intermediateOutputCount,
    'intermediateEntryIndices': turn.intermediateEntryIndices.toList()..sort(),
    'finalAssistantEntryIndex': turn.finalAssistantEntryIndex,
    'currentAssistantEntryIndex': turn.currentAssistantEntryIndex,
    'currentSegmentKey': turn.currentSegment?.key,
    'planUpdateEntryIndices': turn.planUpdateEntryIndices.toList()..sort(),
  };
}

Map<String, Object?> _diagnosticChatEntry(ChatEntry entry) => switch (entry) {
  UserChatEntry() => <String, Object?>{
    'kind': 'user',
    'text': entry.text,
    'sessionId': entry.sessionId,
    'clientMessageId': entry.clientMessageId,
    'providerItemId': entry.providerItemId,
    'historyTurnId': entry.historyTurnId,
    'messageUuid': entry.messageUuid,
    'status': entry.status.name,
    'imageCount': entry.imageCount,
    'memoryImageCount': entry.imageBytesList.length,
    'imageUrls': entry.imageUrls,
  },
  StreamingChatEntry() => <String, Object?>{
    'kind': 'streaming',
    'text': entry.text,
  },
  ServerChatEntry() => <String, Object?>{
    'kind': 'server',
    'message': _diagnosticServerMessage(entry.message),
  },
};

Map<String, Object?> _diagnosticServerMessage(ServerMessage message) {
  return switch (message) {
    AssistantServerMessage() => <String, Object?>{
      'type': 'assistant',
      'id': message.message.id,
      'messageUuid': message.messageUuid,
      'historyTurnId': message.historyTurnId,
      'model': message.message.model,
      'content': [
        for (final content in message.message.content)
          switch (content) {
            TextContent() => <String, Object?>{
              'type': 'text',
              'text': content.text,
            },
            ThinkingContent() => <String, Object?>{
              'type': 'thinking',
              'thinking': content.thinking,
            },
            ToolUseContent() => <String, Object?>{
              'type': 'tool_use',
              'id': content.id,
              'name': content.name,
              'input': content.input,
            },
          },
      ],
    },
    ToolResultMessage() => <String, Object?>{
      'type': 'tool_result',
      'toolUseId': message.toolUseId,
      'toolName': message.toolName,
      'content': message.content,
      'historyTurnId': message.historyTurnId,
      'userMessageUuid': message.userMessageUuid,
      'imageCount': message.images.length,
    },
    ResultMessage() => <String, Object?>{
      'type': 'result',
      'subtype': message.subtype,
      'result': message.result,
      'error': message.error,
      'sessionId': message.sessionId,
      'stopReason': message.stopReason,
      'historyTurnId': message.historyTurnId,
      'cost': message.cost,
      'duration': message.duration,
    },
    SystemMessage() => <String, Object?>{
      'type': 'system',
      'subtype': message.subtype,
      'sessionId': message.sessionId,
      'claudeSessionId': message.claudeSessionId,
      'provider': message.provider,
      'projectPath': message.projectPath,
      'historyTurnId': message.historyTurnId,
      'model': message.model,
      'modelReasoningEffort': message.modelReasoningEffort,
      'serviceTier': message.serviceTier,
      'approvalPolicy': message.approvalPolicy,
      'approvalsReviewer': message.approvalsReviewer,
      'sandboxMode': message.sandboxMode,
      'planMode': message.planMode,
      'clearContext': message.clearContext,
    },
    StatusMessage() => <String, Object?>{
      'type': 'status',
      'status': message.status.name,
      'rawStatus': message.rawStatus,
      'activityAt': message.activityAt,
    },
    ErrorMessage() => <String, Object?>{
      'type': 'error',
      'message': message.message,
      'errorCode': message.errorCode,
      'sessionId': message.sessionId,
      'historyTurnId': message.historyTurnId,
    },
    ToolUseSummaryMessage() => <String, Object?>{
      'type': 'tool_use_summary',
      'summary': message.summary,
      'precedingToolUseIds': message.precedingToolUseIds,
      'historyTurnId': message.historyTurnId,
    },
    GuardianApprovalMessage() => <String, Object?>{
      'type': 'guardian_approval',
      'risk': message.risk.name,
      'status': message.status.name,
      'reason': message.reason,
      'authorization': message.authorization,
      'reviewId': message.reviewId,
      'targetItemId': message.targetItemId,
      'action': message.action,
      'historyTurnId': message.historyTurnId,
    },
    PermissionRequestMessage() => <String, Object?>{
      'type': 'permission_request',
      'toolUseId': message.toolUseId,
      'toolName': message.toolName,
      'input': message.input,
    },
    UserInputMessage() => <String, Object?>{
      'type': 'user_input',
      'text': message.text,
      'clientMessageId': message.clientMessageId,
      'providerItemId': message.providerItemId,
      'historyTurnId': message.historyTurnId,
      'userMessageUuid': message.userMessageUuid,
      'timestamp': message.timestamp,
    },
    InputAckMessage() => <String, Object?>{
      'type': 'input_ack',
      'sessionId': message.sessionId,
      'clientMessageId': message.clientMessageId,
      'acceptedSeq': message.acceptedSeq,
      'queued': message.queued,
      'stage': message.stage?.wireValue,
    },
    InputDeliveryStatusMessage() => <String, Object?>{
      'type': 'input_delivery_status',
      'sessionId': message.sessionId,
      'clientMessageId': message.clientMessageId,
      'stage': message.stage.wireValue,
      'provider': message.provider,
      'method': message.method,
      'providerTurnId': message.providerTurnId,
      'occurredAt': message.occurredAt,
      'acceptedSeq': message.acceptedSeq,
      'queued': message.queued,
    },
    ConversationQueueMessage() => <String, Object?>{
      'type': 'conversation_queue',
      'sessionId': message.sessionId,
      'limit': message.limit,
      'items': [for (final item in message.items) _diagnosticQueuedInput(item)],
    },
    _ => <String, Object?>{'type': message.runtimeType.toString()},
  };
}

Map<String, Object?> _diagnosticQueuedInput(QueuedInputItem item) =>
    <String, Object?>{
      'itemId': item.itemId,
      'text': item.text,
      'createdAt': item.createdAt,
      'updatedAt': item.updatedAt,
      'clientMessageId': item.clientMessageId,
      'deliveryStage': item.deliveryStage?.wireValue,
      'deliveryError': item.deliveryError,
      'imageCount': item.imageCount,
      'skills': item.skills,
      'mentions': item.mentions,
    };

@visibleForTesting
bool shouldLoadOlderLocalHistory(
  ScrollMetrics metrics, {
  double threshold = 480,
}) =>
    metrics.maxScrollExtent > 0 &&
    metrics.pixels >= metrics.maxScrollExtent - threshold;

@visibleForTesting
bool shouldLoadNewerLocalHistory(
  ScrollMetrics metrics, {
  double threshold = 480,
}) => metrics.maxScrollExtent > 0 && metrics.pixels <= threshold;

@visibleForTesting
Set<int> forkableAssistantEntryIndices(
  List<ChatEntry> entries, {
  bool transcriptTailComplete = false,
}) {
  final result = <int>{};
  int? candidate;
  String? candidateTurnId;
  var candidateHasTerminalResult = false;

  void finishCandidate({required bool followedByUser}) {
    if (candidate != null &&
        (followedByUser ||
            candidateHasTerminalResult ||
            transcriptTailComplete)) {
      result.add(candidate!);
    }
    candidate = null;
    candidateTurnId = null;
    candidateHasTerminalResult = false;
  }

  for (var index = 0; index < entries.length; index++) {
    final entry = entries[index];
    if (entry is UserChatEntry) {
      final userTurnId = chatEntryHistoryTurnId(entry);
      if (candidate != null &&
          (candidateTurnId == null ||
              userTurnId == null ||
              userTurnId != candidateTurnId)) {
        finishCandidate(followedByUser: true);
      }
      continue;
    }
    final entryTurnId = chatEntryHistoryTurnId(entry);
    if (candidate != null &&
        candidateTurnId != null &&
        entryTurnId != null &&
        entryTurnId != candidateTurnId) {
      finishCandidate(followedByUser: true);
    }
    if (candidate != null) candidateTurnId ??= entryTurnId;
    if (entry is! ServerChatEntry) continue;
    switch (entry.message) {
      case AssistantServerMessage(:final message):
        final hasVisibleReply = message.content.any(
          (content) => content is TextContent && content.text.trim().isNotEmpty,
        );
        if (hasVisibleReply) {
          candidate = index;
          candidateTurnId = entryTurnId;
          candidateHasTerminalResult = false;
        }
        break;
      case ResultMessage():
        if (candidate != null) candidateHasTerminalResult = true;
        break;
      default:
        break;
    }
  }
  finishCandidate(followedByUser: false);
  return result;
}

/// Displays the chat message list with [ListView.builder] (reverse: true).
///
/// Reads entries directly from [ChatSessionCubit] state (SSOT).
/// With reverse list, offset 0 = bottom of chat, so new messages appear
/// immediately without scroll adjustment, and history prepend does not
/// shift the viewport.
class ChatMessageList extends StatefulWidget {
  final String sessionId;
  final AutoScrollController scrollController;
  final String? httpBaseUrl;
  final void Function(UserChatEntry)? onRetryMessage;
  final void Function(UserChatEntry)? onRewindMessage;
  final void Function(AssistantServerMessage)? onForkMessage;
  final ValueNotifier<int>? collapseToolResults;
  final double bottomPadding;
  final bool isCodex;
  final ValueChanged<String>? onFilePeekOpened;
  final List<ChatSelectionAction> selectionActions;
  final ChatMessageListDiagnosticController? diagnosticController;

  /// Project path for file peek (reading files from Bridge).
  final String? projectPath;

  /// When set (non-null), the list scrolls to the given [UserChatEntry].
  /// The notifier is reset to null after scrolling.
  final ValueNotifier<UserChatEntry?>? scrollToUserEntry;

  const ChatMessageList({
    super.key,
    required this.sessionId,
    required this.scrollController,
    required this.httpBaseUrl,
    required this.onRetryMessage,
    this.onRewindMessage,
    this.onForkMessage,
    required this.collapseToolResults,
    this.scrollToUserEntry,
    this.bottomPadding = 8,
    this.projectPath,
    this.isCodex = false,
    this.onFilePeekOpened,
    this.selectionActions = const [],
    this.diagnosticController,
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  ChatSessionCubit? _pagingCubit;
  List<ChatEntry>? _processLayoutEntries;
  bool? _processLayoutLatestTurnIsActive;
  bool? _processLayoutHasTransientCurrentOutput;
  ChatProcessLayout? _cachedProcessLayout;
  final Set<String> _expandedProcessSegments = {};
  final Set<String> _expandedIntermediateTurns = {};
  final Set<String> _expandedCurrentProgress = {};
  final Map<String, GlobalKey> _disclosureAnchorKeys = {};
  final _generatedImageItemCache =
      <GeneratedImageItemCacheKey, GeneratedImagePreviewItem>{};
  ChatSessionState? _derivedForState;
  List<ChatEntry>? _derivedEntries;
  String? _derivedForHttpBaseUrl;
  bool? _derivedForTranscriptTailComplete;
  _ChatListDerivedData? _derivedData;

  @override
  void initState() {
    super.initState();
    widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    widget.collapseToolResults?.addListener(_onCollapseSignal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextCubit = context.read<ChatSessionCubit>();
    if (identical(nextCubit, _pagingCubit)) return;
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    _pagingCubit?.historyNavigation.removeListener(_onHistoryNavigationChanged);
    _pagingCubit = nextCubit;
    nextCubit.localHistoryPaging.addListener(_onPagingChanged);
    nextCubit.historyNavigation.addListener(_onHistoryNavigationChanged);
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diagnosticController != widget.diagnosticController) {
      oldWidget.diagnosticController?._detach(this);
    }
    if (oldWidget.scrollToUserEntry != widget.scrollToUserEntry) {
      oldWidget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
      widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    }
    if (oldWidget.collapseToolResults != widget.collapseToolResults) {
      oldWidget.collapseToolResults?.removeListener(_onCollapseSignal);
      widget.collapseToolResults?.addListener(_onCollapseSignal);
      _collapseAllState();
    }
  }

  @override
  void dispose() {
    widget.diagnosticController?._detach(this);
    widget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
    widget.collapseToolResults?.removeListener(_onCollapseSignal);
    _pagingCubit?.localHistoryPaging.removeListener(_onPagingChanged);
    _pagingCubit?.historyNavigation.removeListener(_onHistoryNavigationChanged);
    super.dispose();
  }

  void _onCollapseSignal() => _collapseAllState();

  void _collapseAllState() {
    if (_expandedProcessSegments.isEmpty &&
        _expandedIntermediateTurns.isEmpty &&
        _expandedCurrentProgress.isEmpty) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _expandedProcessSegments.clear();
      _expandedIntermediateTurns.clear();
      _expandedCurrentProgress.clear();
    });
  }

  void _onPagingChanged() {
    if (mounted) setState(() {});
  }

  void _onHistoryNavigationChanged() {
    _processLayoutEntries = null;
    _cachedProcessLayout = null;
    _derivedEntries = null;
    _derivedData = null;
    if (mounted) setState(() {});
  }

  void _onScrollToUserEntry() {
    final entry = widget.scrollToUserEntry?.value;
    if (entry == null) return;
    // Reset the notifier
    widget.scrollToUserEntry?.value = null;
    // A history reveal may have switched the list to an isolated viewport in
    // the same microtask. Wait until its AutoScrollTags are mounted before
    // resolving the target index; otherwise the old live list can win the
    // race and leave the user at the wrong position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToUserEntry(entry);
    });
  }

  GlobalKey _anchorKey(String id) =>
      _disclosureAnchorKeys.putIfAbsent(id, GlobalKey.new);

  Widget _anchoredDisclosure(String id, Widget child) =>
      KeyedSubtree(key: _anchorKey(id), child: child);

  ChatProcessLayout _processLayoutFor(
    List<ChatEntry> entries, {
    required bool latestTurnIsActive,
    required bool hasTransientCurrentOutput,
  }) {
    final cached = _cachedProcessLayout;
    if (cached != null &&
        identical(entries, _processLayoutEntries) &&
        latestTurnIsActive == _processLayoutLatestTurnIsActive &&
        hasTransientCurrentOutput == _processLayoutHasTransientCurrentOutput) {
      return cached;
    }
    final layout = buildChatProcessLayout(
      entries,
      latestTurnIsActive: latestTurnIsActive,
      hasTransientCurrentOutput: hasTransientCurrentOutput,
    );
    _migratePartialTurnDisclosureState(layout.turnKeyAliases);
    _processLayoutEntries = entries;
    _processLayoutLatestTurnIsActive = latestTurnIsActive;
    _processLayoutHasTransientCurrentOutput = hasTransientCurrentOutput;
    _cachedProcessLayout = layout;
    return layout;
  }

  void _migratePartialTurnDisclosureState(Map<String, String> turnKeyAliases) {
    for (final alias in turnKeyAliases.entries) {
      final partialKey = alias.key;
      final canonicalKey = alias.value;
      if (_expandedIntermediateTurns.remove(partialKey)) {
        _expandedIntermediateTurns.add(canonicalKey);
      }

      final partialProgressKey = _currentProgressKey(partialKey);
      if (_expandedCurrentProgress.remove(partialProgressKey)) {
        _expandedCurrentProgress.add(_currentProgressKey(canonicalKey));
      }

      final segmentPrefix = '$partialKey:segment:';
      final migratedSegments = <String>[];
      for (final segmentKey in _expandedProcessSegments) {
        if (!segmentKey.startsWith(segmentPrefix)) continue;
        migratedSegments.add(
          '$canonicalKey:segment:${segmentKey.substring(segmentPrefix.length)}',
        );
      }
      if (migratedSegments.isEmpty) continue;
      _expandedProcessSegments.removeWhere(
        (segmentKey) => segmentKey.startsWith(segmentPrefix),
      );
      _expandedProcessSegments.addAll(migratedSegments);
    }
  }

  /// Keeps a user-triggered height change inside the viewport's layout pass.
  /// The custom scroll position corrects the anchor before paint; the callback
  /// below only releases the request and never moves the viewport.
  void _toggleWithStableReadingPosition(String anchorId, VoidCallback mutate) {
    final controller = widget.scrollController;
    final generation = controller is ReadingPositionAutoScrollController
        ? controller.beginAnchorMutation(_anchorKey(anchorId))
        : null;
    setState(mutate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller is ReadingPositionAutoScrollController) {
        controller.endAnchorMutation(generation);
      }
    });
  }

  Future<void> _openArtifact(String messageId, ArtifactRef artifact) async {
    final requestSessionId = widget.sessionId;
    final requestProjectPath = widget.projectPath;
    final sourcePath = artifact.projectRelativePath;
    if (artifact.isSource &&
        (requestProjectPath == null ||
            requestProjectPath.isEmpty ||
            !isSafeProjectRelativePath(sourcePath))) {
      _showArtifactError(AppLocalizations.of(context).artifactUnavailable);
      return;
    }
    final bridge = context.read<BridgeService>();
    if (artifact.isSource) {
      final safeSourcePath = sourcePath!;
      if (shouldPreferUnifiedArtifactPreview(artifact)) {
        try {
          await _openResolvedArtifactPreview(
            bridge: bridge,
            requestSessionId: requestSessionId,
            requestProjectPath: requestProjectPath,
            messageId: messageId,
            artifact: artifact,
          );
          return;
        } on ArtifactResolveException catch (error) {
          // Source refs predate the unified preview route on some Bridges.
          // Preserve their exact File Peek path instead of turning an
          // additive preview improvement into a compatibility break.
          if (error.code != 'artifact_resolve_unsupported') {
            if (mounted && widget.sessionId == requestSessionId) {
              _showArtifactError(_artifactErrorMessage(error.code));
            }
            return;
          }
        } catch (_) {
          if (mounted && widget.sessionId == requestSessionId) {
            _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
          }
          return;
        }
      }
      try {
        // Source refs are opened atomically by identity. Resolving a download
        // URL first creates a TOCTOU window and is unnecessary for File Peek.
        final sourceContent = await bridge.readArtifactSource(
          sessionId: requestSessionId,
          messageId: messageId,
          artifactId: artifact.id,
          filePath: safeSourcePath,
          maxLines: filePeekMaxLinesForInitialLine(artifact.line),
        );
        if (!mounted || widget.sessionId != requestSessionId) return;
        if (widget.projectPath != requestProjectPath) {
          _showArtifactError(AppLocalizations.of(context).artifactUnavailable);
          return;
        }
        if (sourceContent.error != null) {
          _showArtifactError(
            _artifactErrorMessage(sourceContent.errorCode, sourceRead: true),
          );
          return;
        }
        return showFilePeekSheet(
          context,
          bridge: bridge,
          projectPath: requestProjectPath!,
          filePath: safeSourcePath,
          initialLine: artifact.line,
          artifactSessionId: requestSessionId,
          artifactMessageId: messageId,
          artifactId: artifact.id,
          initialContent: sourceContent,
          onOpened: () => widget.onFilePeekOpened?.call(safeSourcePath),
          onOpenPreviewRequested: supportsEmbeddedArtifactPreview()
              ? () async {
                  try {
                    await _openResolvedArtifactPreview(
                      bridge: bridge,
                      requestSessionId: requestSessionId,
                      requestProjectPath: requestProjectPath,
                      messageId: messageId,
                      artifact: artifact,
                    );
                  } on ArtifactResolveException catch (error) {
                    if (mounted && widget.sessionId == requestSessionId) {
                      _showArtifactError(_artifactErrorMessage(error.code));
                    }
                  } catch (_) {
                    if (mounted && widget.sessionId == requestSessionId) {
                      _showArtifactError(
                        AppLocalizations.of(context).artifactOpenFailed,
                      );
                    }
                  }
                }
              : null,
        );
      } on ArtifactSourceReadException catch (error) {
        if (!mounted || widget.sessionId != requestSessionId) return;
        if (widget.projectPath != requestProjectPath) return;
        _showArtifactError(_artifactErrorMessage(error.code, sourceRead: true));
      } catch (_) {
        if (mounted &&
            widget.sessionId == requestSessionId &&
            widget.projectPath == requestProjectPath) {
          _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
        }
      }
      return;
    }
    try {
      await _openResolvedArtifactPreview(
        bridge: bridge,
        requestSessionId: requestSessionId,
        requestProjectPath: requestProjectPath,
        messageId: messageId,
        artifact: artifact,
      );
    } on ArtifactResolveException catch (error) {
      if (!mounted || widget.sessionId != requestSessionId) return;
      _showArtifactError(_artifactErrorMessage(error.code));
    } catch (_) {
      if (mounted && widget.sessionId == requestSessionId) {
        _showArtifactError(AppLocalizations.of(context).artifactOpenFailed);
      }
    }
  }

  Future<void> _openResolvedArtifactPreview({
    required BridgeService bridge,
    required String requestSessionId,
    required String? requestProjectPath,
    required String messageId,
    required ArtifactRef artifact,
  }) async {
    final resolved = await bridge.resolveArtifact(
      sessionId: requestSessionId,
      messageId: messageId,
      artifactId: artifact.id,
    );
    if (!mounted || widget.sessionId != requestSessionId) return;
    if (widget.projectPath != requestProjectPath) {
      throw const ArtifactResolveException(
        code: 'bridge_changed',
        message: 'The active project changed while preparing the file.',
      );
    }
    if (supportsEmbeddedArtifactPreview()) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ArtifactPreviewScreen(
            previewUrl: resolved.url,
            filename: artifact.filename,
            mimeType: artifact.mimeType,
            sizeBytes: artifact.sizeBytes,
            expiresAt: resolved.expiresAt,
            accessRefresher: () async {
              final refreshed = await bridge.resolveArtifact(
                sessionId: requestSessionId,
                messageId: messageId,
                artifactId: artifact.id,
              );
              return ArtifactPreviewAccess(
                previewUrl: refreshed.url,
                expiresAt: refreshed.expiresAt,
              );
            },
          ),
        ),
      );
      return;
    }
    final launched = await launchUrl(
      resolved.url,
      mode: LaunchMode.externalApplication,
    );
    if (!mounted || widget.sessionId != requestSessionId) return;
    if (!launched) {
      throw const ArtifactResolveException(
        code: 'artifact_open_failed',
        message: 'The artifact preview could not be opened.',
      );
    }
  }

  String _artifactErrorMessage(String? code, {bool sourceRead = false}) {
    final localizations = AppLocalizations.of(context);
    return switch (code) {
      'artifact_expired' ||
      'artifact_gone' ||
      'artifact_changed' ||
      'artifact_not_found' ||
      'artifact_unavailable' ||
      'file_gone' ||
      'file_changed' ||
      'file_unreadable' ||
      'path_not_allowed' ||
      'source_path_mismatch' ||
      'session_not_found' => localizations.artifactUnavailable,
      'bridge_disconnected' ||
      'bridge_changed' ||
      'bridge_reconnecting' => localizations.artifactReconnect,
      'artifact_resolve_unsupported' ||
      'artifact_source_read_unsupported' ||
      'unsupported_message' => localizations.artifactBridgeUpdateRequired,
      'artifact_resolve_timeout' ||
      'artifact_source_read_timeout' => localizations.artifactTimeout,
      _ =>
        sourceRead
            ? localizations.artifactOpenFailed
            : localizations.artifactPrepareFailed,
    };
  }

  void _showArtifactError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ---------------------------------------------------------------------------
  // Scroll to user entry
  // ---------------------------------------------------------------------------

  /// Scrolls the chat list to make the given [UserChatEntry] visible.
  ///
  /// Uses [AutoScrollController.scrollToIndex] which handles both on-screen
  /// and off-screen items correctly with variable-height widgets.
  void _scrollToUserEntry(UserChatEntry entry) {
    final entries = context.read<ChatSessionCubit>().visibleEntries;
    final idx = entries.indexOf(entry);
    if (idx < 0) return;
    widget.scrollController.scrollToIndex(
      idx,
      preferPosition: AutoScrollPosition.middle,
      duration: const Duration(milliseconds: 300),
    );
  }

  // ---------------------------------------------------------------------------
  // Plan text resolution
  // ---------------------------------------------------------------------------

  /// For entries with ExitPlanMode, search all entries for a Write tool
  /// targeting `.claude/plans/` to resolve the plan text.
  String? _resolvePlanText(ChatEntry entry) {
    if (entry is! ServerChatEntry) return null;
    final msg = entry.message;
    if (msg is! AssistantServerMessage) return null;
    final hasExitPlan = msg.message.content.any(
      (c) => c is ToolUseContent && c.name == 'ExitPlanMode',
    );
    if (!hasExitPlan) return null;
    return _derivedData?.latestPlanText ?? _findPlanFromWriteTool();
  }

  /// Search all entries in reverse for a Write tool targeting `.claude/plans/`.
  String? _findPlanFromWriteTool() {
    final entries = context.read<ChatSessionCubit>().visibleEntries;
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (entry is! ServerChatEntry) continue;
      final msg = entry.message;
      if (msg is! AssistantServerMessage) continue;
      for (final c in msg.message.content) {
        if (c is! ToolUseContent || c.name != 'Write') continue;
        final filePath = c.input['file_path']?.toString() ?? '';
        if (!filePath.contains('.claude/plans/')) continue;
        final content = c.input['content']?.toString();
        if (content != null && content.isNotEmpty) return content;
      }
    }
    return null;
  }

  Widget _timelineItem({
    required String key,
    required int entryIndex,
    required Widget child,
  }) => ReadingPositionItem(
    child: AutoScrollTag(
      key: ValueKey(key),
      controller: widget.scrollController,
      index: entryIndex,
      child: child,
    ),
  );

  Widget _buildTranscriptEntry({
    required List<ChatEntry> entries,
    required int entryIndex,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required bool showAssistantProcessDetails,
  }) {
    final entry = entries[entryIndex];
    final previous = entryIndex > 0 ? entries[entryIndex - 1] : null;
    final onForkMessage =
        widget.isCodex &&
            (_derivedData?.forkableAssistantEntryIndices.contains(entryIndex) ??
                shouldShowForkForAssistant(
                  entries,
                  entryIndex,
                  transcriptTailComplete: transcriptTailComplete,
                ))
        ? widget.onForkMessage
        : null;
    final fileRoot = widget.projectPath;
    final chatCubit = context.read<ChatSessionCubit>();
    return ChatEntryWidget(
      entry: entry,
      previous: previous,
      httpBaseUrl: widget.httpBaseUrl,
      sessionId: widget.sessionId,
      projectPath: widget.projectPath,
      onRetryMessage: widget.onRetryMessage,
      onRewindMessage: widget.onRewindMessage,
      onForkMessage: onForkMessage,
      onDismissCodexWarning: chatCubit.dismissCodexWarning,
      collapseToolResults: widget.collapseToolResults,
      showAssistantProcessDetails: showAssistantProcessDetails,
      resolvedPlanText: _resolvePlanText(entry),
      hiddenToolUseIds: hiddenToolUseIds,
      onArtifactOpen: _openArtifact,
      isCodex: widget.isCodex,
      onFileTap: fileRoot?.isNotEmpty == true
          ? (filePath) {
              openFilePeek(
                context,
                bridge: context.read<BridgeService>(),
                projectPath: fileRoot!,
                filePath: filePath,
                projectFiles: context.read<FileListCubit>().state,
                onResolvedFilePath: widget.onFilePeekOpened,
              );
            }
          : null,
      onImageTap: (user) {
        final claudeSessionId = chatCubit.state.claudeSessionId;
        final httpBaseUrl = widget.httpBaseUrl;
        if (claudeSessionId == null ||
            claudeSessionId.isEmpty ||
            httpBaseUrl == null) {
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MessageImagesScreen(
              bridge: context.read<BridgeService>(),
              httpBaseUrl: httpBaseUrl,
              claudeSessionId: claudeSessionId,
              messageUuid: user.messageUuid!,
              imageCount: user.imageCount,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAssistantProcessDetails(
    List<ChatEntry> entries,
    int entryIndex,
    Set<String> hiddenToolUseIds,
  ) {
    final entry = entries[entryIndex];
    if (entry case ServerChatEntry(
      message: final AssistantServerMessage message,
    )) {
      return AssistantProcessDetails(
        message: message,
        collapseNotifier: widget.collapseToolResults,
        hiddenToolUseIds: hiddenToolUseIds,
        historyToolDetailGapBuilder: (gap) => _HistoryToolDetailGapView(
          key: ValueKey('history_tool_detail_view_${gap.gapId}'),
          cubit: context.read<ChatSessionCubit>(),
          gap: gap,
          httpBaseUrl: widget.httpBaseUrl,
          sessionId: widget.sessionId,
          projectPath: widget.projectPath,
          collapseNotifier: widget.collapseToolResults,
          onFilePeekOpened: widget.onFilePeekOpened,
          onArtifactOpen: _openArtifact,
        ),
      );
    }
    return const SizedBox.shrink();
  }

  List<Widget> _buildProcessSegmentDetails({
    required ChatProcessSegmentLayout segment,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
    Set<int> excludedProcessEntryIndices = const {},
  }) {
    final details = <Widget>[];
    if (segment.assistantEntryIndex case final assistantIndex?
        when segment.hasInlineAssistantProcess) {
      details.add(
        KeyedSubtree(
          key: ValueKey('chat_process_inline_${segment.key}'),
          child: _buildAssistantProcessDetails(
            entries,
            assistantIndex,
            hiddenToolUseIds,
          ),
        ),
      );
    }
    final processIndices = segment.processEntryIndices.toList()..sort();
    for (final processIndex in processIndices) {
      if (excludedProcessEntryIndices.contains(processIndex)) continue;
      details.add(
        KeyedSubtree(
          key: ValueKey('chat_process_entry_${segment.key}_$processIndex'),
          child: switch (imageItemsByAnchor[processIndex]) {
            final items? => GeneratedImageChatGroup(items: items),
            _ when imageGroupMemberIndices.contains(processIndex) =>
              const SizedBox.shrink(),
            _ => _buildTranscriptEntry(
              entries: entries,
              entryIndex: processIndex,
              hiddenToolUseIds: hiddenToolUseIds,
              transcriptTailComplete: transcriptTailComplete,
              showAssistantProcessDetails: true,
            ),
          },
        ),
      );
    }
    return details;
  }

  Widget _buildHistoricalProcessGroup({
    required ChatProcessSegmentLayout segment,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
  }) {
    final expanded = _expandedProcessSegments.contains(segment.key);
    final children = <Widget>[];
    if (segment.assistantEntryIndex case final assistantIndex?) {
      children.add(
        _buildTranscriptEntry(
          entries: entries,
          entryIndex: assistantIndex,
          hiddenToolUseIds: hiddenToolUseIds,
          transcriptTailComplete: transcriptTailComplete,
          showAssistantProcessDetails: false,
        ),
      );
    }
    if (segment.detailCount > 0) {
      children.add(
        _anchoredDisclosure(
          'process:${segment.key}',
          ChatProcessDisclosure(
            segment: segment,
            expanded: expanded,
            onToggle: () => _toggleProcessSegment(segment.key),
            timestamp: _timestampForEntryIndex(entries, segment.lastEntryIndex),
          ),
        ),
      );
      if (expanded) {
        children.add(
          _ProcessDetailsViewport(
            key: ValueKey('process_details_viewport_${segment.key}'),
            expanded: true,
            children: _buildProcessSegmentDetails(
              segment: segment,
              entries: entries,
              hiddenToolUseIds: hiddenToolUseIds,
              transcriptTailComplete: transcriptTailComplete,
              imageItemsByAnchor: imageItemsByAnchor,
              imageGroupMemberIndices: imageGroupMemberIndices,
            ),
          ),
        );
      }
    }
    return Column(
      key: ValueKey('chat_process_group_${segment.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildCurrentProcessGroup({
    required ChatProcessTurnLayout turn,
    required ChatProcessSegmentLayout segment,
    required String progressKey,
    required List<ChatEntry> entries,
    required Set<String> hiddenToolUseIds,
    required bool transcriptTailComplete,
    required Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor,
    required Set<int> imageGroupMemberIndices,
  }) {
    final expanded = _expandedCurrentProgress.contains(progressKey);
    final currentTool = turn.currentTool;
    final hasDetails = segment.detailCount > 0 || currentTool != null;
    final children = <Widget>[
      _anchoredDisclosure(
        'current:$progressKey',
        ChatCurrentProgressHeader(
          turnKey: progressKey,
          expanded: expanded,
          hasDetails: hasDetails,
          onToggle: () => _toggleCurrentProgress(progressKey),
        ),
      ),
    ];
    if (segment.assistantEntryIndex case final assistantIndex?) {
      children.add(
        _buildTranscriptEntry(
          entries: entries,
          entryIndex: assistantIndex,
          hiddenToolUseIds: hiddenToolUseIds,
          transcriptTailComplete: transcriptTailComplete,
          showAssistantProcessDetails: false,
        ),
      );
    }
    if (currentTool != null || expanded) {
      children.add(
        _ProcessDetailsViewport(
          key: ValueKey('process_details_viewport_current_$progressKey'),
          expanded: expanded,
          transientGuardianReview: currentTool?.guardianReview,
          pinnedHeader: currentTool == null
              ? null
              : ChatCurrentToolActivityLine(
                  activity: currentTool,
                  expanded: expanded,
                  onTap: () => _toggleCurrentProgress(progressKey),
                  timestamp: _timestampForEntryIndex(
                    entries,
                    currentTool.entryIndex,
                  ),
                ),
          children: [
            if (expanded)
              ..._buildProcessSegmentDetails(
                segment: segment,
                entries: entries,
                hiddenToolUseIds: hiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
                excludedProcessEntryIndices:
                    segment.attachedGuardianEntryIndices,
              ),
          ],
        ),
      );
    }
    return Column(
      key: ValueKey('chat_current_process_group_${turn.key}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    chatListPerformanceProbe.recordBuild();
    final chatCubit = context.watch<ChatSessionCubit>();
    final chatState = chatCubit.state;
    final hiddenToolUseIds = chatState.hiddenToolUseIds;
    final historyBrowsing = chatCubit.historyNavigationActive;
    final allEntries = chatCubit.visibleEntries;

    // Watch only the isStreaming flag (not the full streaming text) so the
    // list rebuilds when streaming starts/stops (to adjust itemCount) but NOT
    // on every text delta. The actual streaming text is rendered inside a
    // scoped BlocBuilder on the streaming item only.
    final streamingActive = context.select<StreamingStateCubit, bool>(
      (cubit) => cubit.state.isStreaming,
    );
    final hasStreaming = !historyBrowsing && streamingActive;
    final latestTurnIsActive =
        !historyBrowsing &&
        (chatState.status == ProcessStatus.running ||
            chatState.status == ProcessStatus.waitingApproval ||
            chatState.status == ProcessStatus.compacting ||
            chatState.externalDesktopTurnActive ||
            hasStreaming);
    final processLayout = _processLayoutFor(
      allEntries,
      latestTurnIsActive: latestTurnIsActive,
      hasTransientCurrentOutput: hasStreaming,
    );
    final messageCount = allEntries.length + (hasStreaming ? 1 : 0);
    final transcriptTailComplete =
        chatState.status == ProcessStatus.idle &&
        chatState.queuedInput == null &&
        !hasStreaming;
    final derivedData = _deriveData(
      chatState,
      allEntries,
      transcriptTailComplete: transcriptTailComplete,
    );
    final imageItemsByAnchor = derivedData.imageItemsByAnchor;
    final imageGroupMemberIndices = derivedData.imageGroupMemberIndices;
    final effectiveHiddenToolUseIds = {
      ...hiddenToolUseIds,
      ...derivedData.completedGeneratedImageToolUseIds,
    };

    final paging = chatCubit.localHistoryPaging.value;
    widget.diagnosticController?._attach(
      _ChatMessageListDiagnosticSource(
        owner: this,
        sessionId: widget.sessionId,
        entries: allEntries,
        layout: processLayout,
        chatState: chatState,
        paging: paging,
        historyBrowsing: historyBrowsing,
        latestTurnIsActive: latestTurnIsActive,
        hasStreaming: hasStreaming,
        streamingCubit: context.read<StreamingStateCubit>(),
        scrollController: widget.scrollController,
        expandedProcessSegments: _expandedProcessSegments,
        expandedIntermediateTurns: _expandedIntermediateTurns,
        expandedCurrentProgress: _expandedCurrentProgress,
        imageItemsByAnchor: imageItemsByAnchor,
        imageGroupMemberIndices: imageGroupMemberIndices,
      ),
    );
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Only unfocus when user drags the list (not programmatic scroll).
        // This prevents the keyboard from being dismissed during automatic
        // scroll-to-bottom triggered by streaming updates.
        if (notification is UserScrollNotification) {
          if (notification.direction != ScrollDirection.idle) {
            FocusScope.of(context).unfocus();
          }
        }
        if (paging.enabled &&
            paging.hasMore &&
            shouldLoadOlderLocalHistory(notification.metrics)) {
          unawaited(chatCubit.loadOlderLocalHistory());
        }
        if (paging.enabled &&
            paging.hasLater &&
            notification is ScrollUpdateNotification &&
            notification.dragDetails != null &&
            shouldLoadNewerLocalHistory(notification.metrics)) {
          unawaited(chatCubit.loadNewerLocalHistory());
        }
        return false;
      },
      child: ListView.builder(
        controller: widget.scrollController,
        reverse: true,
        physics: MaintainReadingPositionPhysics(
          shouldMaintain: () {
            final controller = widget.scrollController;
            return controller is! ReadingPositionAutoScrollController ||
                !controller.suppressPassiveExtentCorrection;
          },
        ),
        padding: EdgeInsets.only(top: 36, bottom: widget.bottomPadding),
        itemCount:
            messageCount +
            ((paging.enabled &&
                    (paging.hasMore || paging.loading || paging.error != null))
                ? 1
                : 0) +
            (historyBrowsing ? 1 : 0),
        itemBuilder: (context, index) {
          if (historyBrowsing && index == 0) {
            return _LocalHistoryNewerPageIndicator(
              paging: paging,
              onRetry: chatCubit.loadNewerLocalHistory,
              onReturnToLatest: () {
                chatCubit.exitHistoryNavigation();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !widget.scrollController.hasClients) return;
                  widget.scrollController.animateTo(
                    widget.scrollController.position.minScrollExtent,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  );
                });
              },
            );
          }
          final transcriptIndex = index - (historyBrowsing ? 1 : 0);
          if (transcriptIndex == messageCount) {
            if (paging.hasMore && !paging.loading && paging.error == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) unawaited(chatCubit.loadOlderLocalHistory());
              });
            }
            return _LocalHistoryPageIndicator(
              paging: paging,
              onRetry: () async {
                await chatCubit.loadOlderLocalHistory();
              },
            );
          }
          // index 0 = newest entry (bottom of chat)
          // Map to actual entry index:
          final entryIndex = messageCount - 1 - transcriptIndex;

          // Streaming entry is at messageCount - 1 (index 0 in reverse)
          if (hasStreaming && entryIndex == allEntries.length) {
            // Scoped BlocBuilder: only this widget rebuilds on streaming deltas
            final turn = processLayout.latestTurn;
            final turnKey =
                turn?.key ??
                processLayout.latestTurnKey ??
                'session:${widget.sessionId}';
            final progressKey = _currentProgressKey(turnKey);
            return ReadingPositionItem(
              child: _anchoredDisclosure(
                'current:$progressKey',
                BlocSelector<StreamingStateCubit, StreamingState, bool>(
                  selector: (state) => state.isStreaming,
                  builder: (context, streamingState) {
                    if (!streamingState) {
                      return const SizedBox.shrink();
                    }
                    final currentTool = turn?.currentTool;
                    final expanded = _expandedCurrentProgress.contains(
                      progressKey,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        BlocSelector<StreamingStateCubit, StreamingState, bool>(
                          selector: (state) => state.thinking.trim().isNotEmpty,
                          builder: (context, hasThinking) {
                            return ChatCurrentProgressHeader(
                              turnKey: progressKey,
                              expanded: expanded,
                              hasDetails: hasThinking || currentTool != null,
                              onToggle: () =>
                                  _toggleCurrentProgress(progressKey),
                            );
                          },
                        ),
                        BlocSelector<
                          StreamingStateCubit,
                          StreamingState,
                          String
                        >(
                          selector: (state) => state.text,
                          builder: (context, text) {
                            if (text.isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return ChatEntryWidget(
                              entry: StreamingChatEntry(text: text),
                              previous: null,
                              httpBaseUrl: widget.httpBaseUrl,
                              sessionId: widget.sessionId,
                              projectPath: widget.projectPath,
                              onRetryMessage: null,
                              collapseToolResults: null,
                              hiddenToolUseIds: const {},
                              isCodex: widget.isCodex,
                            );
                          },
                        ),
                        if (currentTool != null || expanded)
                          _ProcessDetailsViewport(
                            key: ValueKey(
                              'live_process_details_viewport_$progressKey',
                            ),
                            expanded: expanded,
                            transientGuardianReview:
                                currentTool?.guardianReview,
                            pinnedHeader: currentTool == null
                                ? null
                                : ChatCurrentToolActivityLine(
                                    activity: currentTool,
                                    expanded: expanded,
                                    onTap: () =>
                                        _toggleCurrentProgress(progressKey),
                                    timestamp: _timestampForEntryIndex(
                                      allEntries,
                                      currentTool.entryIndex,
                                    ),
                                  ),
                            children: [
                              if (expanded)
                                BlocSelector<
                                  StreamingStateCubit,
                                  StreamingState,
                                  String
                                >(
                                  selector: (state) => state.thinking.trim(),
                                  builder: (context, thinking) {
                                    if (thinking.isEmpty) {
                                      return const SizedBox.shrink();
                                    }
                                    return ChatLiveThinkingDetails(
                                      text: thinking,
                                    );
                                  },
                                ),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            );
          }

          final entry = allEntries[entryIndex];
          final processSegment = processLayout.segmentForEntry(entryIndex);
          final intermediateTurn = processLayout.turnForEntry(entryIndex);
          if (intermediateTurn?.isPlanUpdateEntry(entryIndex) == true) {
            if (!intermediateTurn!.showsPlanUpdateAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final input = intermediateTurn.latestPlanUpdateInput;
            if (input == null) return const SizedBox.shrink();
            return _timelineItem(
              key: 'plan_update:${intermediateTurn.key}',
              entryIndex: entryIndex,
              child: TodoWriteWidget(
                key: ValueKey('live_plan_update_${intermediateTurn.key}'),
                input: input,
                collapseNotifier: widget.collapseToolResults,
              ),
            );
          }
          final isIntermediateEntry =
              intermediateTurn?.isIntermediateEntry(entryIndex) == true;
          // One outer fold is one real ListView item. Its temporary outputs,
          // nested disclosures and process details are descendants of that
          // item instead of independently appearing/disappearing peer rows.
          if (isIntermediateEntry) {
            if (intermediateTurn == null ||
                !intermediateTurn.showsIntermediateSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final intermediateExpanded = _expandedIntermediateTurns.contains(
              intermediateTurn.key,
            );
            return _timelineItem(
              key: 'intermediate:${intermediateTurn.key}',
              entryIndex: entryIndex,
              child: ChatIntermediateProcessGroup(
                turn: intermediateTurn,
                expanded: intermediateExpanded,
                outerDisclosure: _anchoredDisclosure(
                  'intermediate:${intermediateTurn.key}',
                  ChatIntermediateOutputsDisclosure(
                    turn: intermediateTurn,
                    expanded: intermediateExpanded,
                    onToggle: () =>
                        _toggleIntermediateTurn(intermediateTurn.key),
                    timestamp: _timestampForEntryIndex(
                      allEntries,
                      intermediateTurn.intermediateSegments.isNotEmpty
                          ? intermediateTurn
                                .intermediateSegments
                                .last
                                .lastEntryIndex
                          : intermediateTurn.intermediateSummaryEntryIndex,
                    ),
                  ),
                ),
                segmentBuilder: (segment) => _buildHistoricalProcessGroup(
                  segment: segment,
                  entries: allEntries,
                  hiddenToolUseIds: effectiveHiddenToolUseIds,
                  transcriptTailComplete: transcriptTailComplete,
                  imageItemsByAnchor: imageItemsByAnchor,
                  imageGroupMemberIndices: imageGroupMemberIndices,
                ),
                auxiliaryEntryBuilder: (entryIndex) =>
                    switch (imageItemsByAnchor[entryIndex]) {
                      final items? => GeneratedImageChatGroup(items: items),
                      _ when imageGroupMemberIndices.contains(entryIndex) =>
                        const SizedBox.shrink(),
                      _ => _buildTranscriptEntry(
                        entries: allEntries,
                        entryIndex: entryIndex,
                        hiddenToolUseIds: effectiveHiddenToolUseIds,
                        transcriptTailComplete: transcriptTailComplete,
                        showAssistantProcessDetails: true,
                      ),
                    },
              ),
            );
          }

          final currentSegment = intermediateTurn?.currentSegment;
          final isCurrentSegmentEntry =
              !hasStreaming &&
              currentSegment != null &&
              currentSegment.containsEntry(entryIndex);
          if (isCurrentSegmentEntry) {
            if (!currentSegment.showsSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final progressKey = _currentProgressKey(intermediateTurn!.key);
            return _timelineItem(
              key: 'current:$progressKey',
              entryIndex: entryIndex,
              child: _buildCurrentProcessGroup(
                turn: intermediateTurn,
                segment: currentSegment,
                progressKey: progressKey,
                entries: allEntries,
                hiddenToolUseIds: effectiveHiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
              ),
            );
          }

          if (processSegment != null) {
            if (!processSegment.showsSummaryAt(entryIndex)) {
              return const SizedBox.shrink();
            }
            final itemKey = processSegment.assistantEntryIndex != null
                ? _entryKey(entry)
                : 'process:${processSegment.key}';
            return _timelineItem(
              key: itemKey,
              entryIndex: entryIndex,
              child: _buildHistoricalProcessGroup(
                segment: processSegment,
                entries: allEntries,
                hiddenToolUseIds: effectiveHiddenToolUseIds,
                transcriptTailComplete: transcriptTailComplete,
                imageItemsByAnchor: imageItemsByAnchor,
                imageGroupMemberIndices: imageGroupMemberIndices,
              ),
            );
          }

          final imageItems = imageItemsByAnchor[entryIndex];
          return _timelineItem(
            key: _entryKey(entry),
            entryIndex: entryIndex,
            child: imageItems != null
                ? GeneratedImageChatGroup(items: imageItems)
                : imageGroupMemberIndices.contains(entryIndex)
                ? const SizedBox.shrink()
                : _buildTranscriptEntry(
                    entries: allEntries,
                    entryIndex: entryIndex,
                    hiddenToolUseIds: effectiveHiddenToolUseIds,
                    transcriptTailComplete: transcriptTailComplete,
                    showAssistantProcessDetails: true,
                  ),
          );
        },
      ),
    );
    if (widget.selectionActions.isEmpty) return content;
    return ChatSelectionActionsScope(
      actions: widget.selectionActions,
      child: content,
    );
  }

  _ChatListDerivedData _deriveData(
    ChatSessionState chatState,
    List<ChatEntry> entries, {
    required bool transcriptTailComplete,
  }) {
    final cached = _derivedData;
    if (_derivedForHttpBaseUrl == widget.httpBaseUrl &&
        _derivedForTranscriptTailComplete == transcriptTailComplete &&
        cached != null) {
      if (identical(_derivedForState, chatState)) return cached;
      final previousEntries = _derivedEntries;
      if (previousEntries != null && listEquals(previousEntries, entries)) {
        _derivedForState = chatState;
        return cached;
      }
    }

    final stopwatch = kDebugMode ? (Stopwatch()..start()) : null;
    final imageGroupMemberIndices = <int>{};
    final imageItemsByAnchor = <int, List<GeneratedImagePreviewItem>>{};
    for (final group in groupGeneratedImageResponses(entries)) {
      final items = generatedImageItemsFromToolResults(
        group.messages,
        httpBaseUrl: widget.httpBaseUrl,
        itemCache: _generatedImageItemCache,
      );
      if (items.isEmpty) continue;
      imageItemsByAnchor[group.anchorEntryIndex] = items;
      imageGroupMemberIndices.addAll(group.memberEntryIndices);
    }
    final next = _ChatListDerivedData(
      imageGroupMemberIndices: imageGroupMemberIndices,
      imageItemsByAnchor: imageItemsByAnchor,
      completedGeneratedImageToolUseIds: completedGeneratedImageToolUseIds(
        entries,
      ),
      forkableAssistantEntryIndices: forkableAssistantEntryIndices(
        entries,
        transcriptTailComplete: transcriptTailComplete,
      ),
      latestPlanText: _findPlanFromWriteTool(),
    );
    _derivedForState = chatState;
    _derivedEntries = entries;
    _derivedForHttpBaseUrl = widget.httpBaseUrl;
    _derivedForTranscriptTailComplete = transcriptTailComplete;
    _derivedData = next;
    stopwatch?.stop();
    if (stopwatch != null) {
      chatListPerformanceProbe.recordDerivedData(stopwatch.elapsed);
    }
    return next;
  }

  void _toggleProcessSegment(String segmentKey) {
    _toggleWithStableReadingPosition('process:$segmentKey', () {
      if (!_expandedProcessSegments.add(segmentKey)) {
        _expandedProcessSegments.remove(segmentKey);
      }
    });
  }

  void _toggleIntermediateTurn(String turnKey) {
    _toggleWithStableReadingPosition('intermediate:$turnKey', () {
      if (!_expandedIntermediateTurns.add(turnKey)) {
        _expandedIntermediateTurns.remove(turnKey);
      }
    });
  }

  void _toggleCurrentProgress(String progressKey) {
    _toggleWithStableReadingPosition('current:$progressKey', () {
      if (!_expandedCurrentProgress.add(progressKey)) {
        _expandedCurrentProgress.remove(progressKey);
      }
    });
  }

  String _entryKey(ChatEntry entry) {
    return chatMessageEntryStableKey(entry);
  }
}

class _ChatListDerivedData {
  final Set<int> imageGroupMemberIndices;
  final Map<int, List<GeneratedImagePreviewItem>> imageItemsByAnchor;
  final Set<String> completedGeneratedImageToolUseIds;
  final Set<int> forkableAssistantEntryIndices;
  final String? latestPlanText;

  const _ChatListDerivedData({
    required this.imageGroupMemberIndices,
    required this.imageItemsByAnchor,
    required this.completedGeneratedImageToolUseIds,
    required this.forkableAssistantEntryIndices,
    required this.latestPlanText,
  });
}

String _currentProgressKey(String turnKey) => 'turn:$turnKey';

ChatMessageTimestampData? _timestampForEntryIndex(
  List<ChatEntry> entries,
  int? entryIndex,
) {
  if (entryIndex == null || entryIndex < 0 || entryIndex >= entries.length) {
    return null;
  }
  return ChatMessageTimestampData.fromEntry(entries[entryIndex]);
}

class _ProcessDetailsViewport extends StatefulWidget {
  const _ProcessDetailsViewport({
    super.key,
    required this.expanded,
    required this.children,
    this.pinnedHeader,
    this.transientGuardianReview,
  });

  final bool expanded;
  final List<Widget> children;
  final Widget? pinnedHeader;
  final GuardianApprovalMessage? transientGuardianReview;

  @override
  State<_ProcessDetailsViewport> createState() =>
      _ProcessDetailsViewportState();
}

class _ProcessDetailsViewportState extends State<_ProcessDetailsViewport> {
  static const _maximumVisibleRows = 8;
  static const _compactRowExtent = 44.0;
  static const _guardianVisibility = Duration(seconds: 3);
  final ScrollController _controller = ScrollController();
  Timer? _guardianTimer;
  String? _guardianIdentity;
  bool _showGuardian = false;

  @override
  void initState() {
    super.initState();
    _syncGuardianReview();
  }

  @override
  void didUpdateWidget(covariant _ProcessDetailsViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncGuardianReview();
  }

  @override
  void dispose() {
    _guardianTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _syncGuardianReview() {
    final review = widget.transientGuardianReview;
    final identity = review == null ? null : chatGuardianReviewIdentity(review);
    if (identity == _guardianIdentity) return;
    _guardianTimer?.cancel();
    _guardianIdentity = identity;
    _showGuardian = review != null;
    if (review == null) return;
    _guardianTimer = Timer(_guardianVisibility, () {
      if (!mounted || _guardianIdentity != identity) return;
      setState(() => _showGuardian = false);
    });
  }

  List<Widget> get _visibleScrollableChildren {
    final review = widget.transientGuardianReview;
    return [
      ...widget.children,
      if (_showGuardian && review != null)
        KeyedSubtree(
          key: ValueKey(
            'chat_current_guardian_${chatGuardianReviewIdentity(review)}',
          ),
          child: GuardianApprovalNotice(message: review),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [?widget.pinnedHeader, ..._visibleScrollableChildren],
      );
    }
    final media = MediaQuery.of(context);
    final textScale = media.textScaler.scale(1).clamp(1.0, 1.6).toDouble();
    final eightRowHeight = _compactRowExtent * _maximumVisibleRows * textScale;
    final screenHeightCap = media.size.height * 0.55;
    final maximumHeight = eightRowHeight < screenHeightCap
        ? eightRowHeight
        : screenHeightCap;

    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 2, 0, 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maximumHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?widget.pinnedHeader,
                if (_visibleScrollableChildren.isNotEmpty)
                  Flexible(
                    fit: FlexFit.loose,
                    child: NotificationListener<ScrollNotification>(
                      // This nested viewport owns its vertical gesture. Do not
                      // let its metrics trigger older-history pagination.
                      onNotification: (_) => true,
                      child: Scrollbar(
                        controller: _controller,
                        child: SingleChildScrollView(
                          key: const ValueKey('process_details_scroll_view'),
                          controller: _controller,
                          primary: false,
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _visibleScrollableChildren,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryToolDetailGapView extends StatefulWidget {
  const _HistoryToolDetailGapView({
    super.key,
    required this.cubit,
    required this.gap,
    required this.sessionId,
    required this.onArtifactOpen,
    this.httpBaseUrl,
    this.projectPath,
    this.collapseNotifier,
    this.onFilePeekOpened,
  });

  final ChatSessionCubit cubit;
  final HistoryToolDetailGap gap;
  final String sessionId;
  final String? httpBaseUrl;
  final String? projectPath;
  final ValueNotifier<int>? collapseNotifier;
  final ValueChanged<String>? onFilePeekOpened;
  final Future<void> Function(String messageId, ArtifactRef artifact)
  onArtifactOpen;

  @override
  State<_HistoryToolDetailGapView> createState() =>
      _HistoryToolDetailGapViewState();
}

class _HistoryToolDetailGapViewState extends State<_HistoryToolDetailGapView> {
  @override
  void initState() {
    super.initState();
    _scheduleInitialPage();
  }

  @override
  void didUpdateWidget(_HistoryToolDetailGapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gap.gapId != widget.gap.gapId) {
      _scheduleInitialPage();
    }
  }

  void _scheduleInitialPage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.cubit.isClosed) return;
      final state = widget.cubit.historyToolDetailState(widget.gap.gapId);
      if (state.details.isEmpty &&
          !state.loading &&
          !state.complete &&
          state.error == null) {
        unawaited(widget.cubit.loadHistoryToolDetailGap(widget.gap));
      }
    });
  }

  void _openFile(String filePath) {
    final projectPath = widget.projectPath;
    if (projectPath == null || projectPath.isEmpty) return;
    openFilePeek(
      context,
      bridge: context.read<BridgeService>(),
      projectPath: projectPath,
      filePath: filePath,
      projectFiles: context.read<FileListCubit>().state,
      onResolvedFilePath: widget.onFilePeekOpened,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.cubit.historyToolDetailRevision,
      builder: (context, _, _) {
        final loadState = widget.cubit.historyToolDetailState(widget.gap.gapId);
        return Column(
          key: ValueKey('history_tool_detail_gap_content_${widget.gap.gapId}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final detail in loadState.details) ...[
              ToolUseTile(
                key: ValueKey(
                  'history_tool_use_${widget.gap.gapId}_${detail.toolUseId}',
                ),
                toolUseId: detail.toolUseId,
                name: detail.toolName,
                input: detail.input,
                collapseNotifier: widget.collapseNotifier,
              ),
              if (detail.result case final result?)
                ToolResultBubble(
                  key: ValueKey(
                    'history_tool_result_'
                    '${widget.gap.gapId}_${detail.toolUseId}',
                  ),
                  message: result,
                  httpBaseUrl: widget.httpBaseUrl,
                  sessionId: widget.sessionId,
                  projectPath: widget.projectPath,
                  onFileTap: widget.projectPath?.isNotEmpty == true
                      ? _openFile
                      : null,
                  onArtifactOpen: result.artifacts.isEmpty
                      ? null
                      : (artifact) =>
                            widget.onArtifactOpen(detail.toolUseId, artifact),
                  collapseNotifier: widget.collapseNotifier,
                ),
            ],
            _HistoryToolDetailLoadControl(
              gap: widget.gap,
              state: loadState,
              onLoad: () =>
                  unawaited(widget.cubit.loadHistoryToolDetailGap(widget.gap)),
            ),
          ],
        );
      },
    );
  }
}

class _HistoryToolDetailLoadControl extends StatelessWidget {
  const _HistoryToolDetailLoadControl({
    required this.gap,
    required this.state,
    required this.onLoad,
  });

  final HistoryToolDetailGap gap;
  final HistoryToolDetailLoadState state;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    if (state.complete) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final remaining = gap.toolUseIds.length - state.nextOffset;
    final nextCount = remaining > 8 ? 8 : remaining;
    final colors = Theme.of(context).colorScheme;
    if (state.loading) {
      return Padding(
        key: ValueKey('history_tool_detail_loading_${gap.gapId}'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            const SizedBox(width: 9),
            Text(
              l.loadingOlderToolDetails,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (state.error != null) {
      return Padding(
        key: ValueKey('history_tool_detail_error_${gap.gapId}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: TextButton.icon(
          onPressed: onLoad,
          icon: const Icon(Icons.refresh, size: 17),
          label: Text(l.loadToolDetailsFailed),
        ),
      );
    }
    return Padding(
      key: ValueKey('history_tool_detail_more_${gap.gapId}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: TextButton.icon(
        onPressed: nextCount > 0 ? onLoad : null,
        icon: const Icon(Icons.expand_more, size: 18),
        label: Text(l.loadNextToolDetails(nextCount)),
      ),
    );
  }
}

class _LocalHistoryPageIndicator extends StatelessWidget {
  const _LocalHistoryPageIndicator({
    required this.paging,
    required this.onRetry,
  });

  final LocalHistoryPagingState paging;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (paging.error != null) {
      return Center(
        child: TextButton.icon(
          key: const ValueKey('local_history_retry'),
          onPressed: () => unawaited(onRetry()),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(AppLocalizations.of(context).retry),
        ),
      );
    }
    return const Padding(
      key: ValueKey('local_history_loading'),
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _LocalHistoryNewerPageIndicator extends StatelessWidget {
  const _LocalHistoryNewerPageIndicator({
    required this.paging,
    required this.onRetry,
    required this.onReturnToLatest,
  });

  final LocalHistoryPagingState paging;
  final Future<bool> Function() onRetry;
  final VoidCallback onReturnToLatest;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (paging.loadingLater) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const SizedBox.square(
              key: ValueKey('local_history_newer_loading'),
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            _returnToLatestButton(l),
          ],
        ),
      );
    }
    if (paging.laterError != null || paging.hasLater) {
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            key: const ValueKey('local_history_newer_retry'),
            onPressed: () => unawaited(onRetry()),
            icon: Icon(
              paging.laterError == null ? Icons.expand_more : Icons.refresh,
              size: 18,
            ),
            label: Text(paging.laterError == null ? l.loadMore : l.retry),
          ),
          _returnToLatestButton(l),
        ],
      );
    }
    return Center(child: _returnToLatestButton(l));
  }

  Widget _returnToLatestButton(AppLocalizations l) {
    return TextButton.icon(
      key: const ValueKey('local_history_return_latest'),
      onPressed: onReturnToLatest,
      icon: const Icon(Icons.vertical_align_bottom, size: 18),
      label: Text(l.scrollToBottom),
    );
  }
}
