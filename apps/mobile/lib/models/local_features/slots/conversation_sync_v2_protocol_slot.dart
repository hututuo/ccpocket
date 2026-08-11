part of '../../messages.dart';

const conversationSyncV2Capability = 'conversation_sync_v2';
const conversationWindowCoverageCapability =
    'conversation_sync_window_coverage_v1';
const conversationSyncFocusRefreshCapability =
    'conversation_sync_focus_refresh_v1';
const conversationItemsByIdCapability = 'conversation_items_by_id_v1';
const conversationUserIndexCapability = 'conversation_user_index_v1';
const appServerStatusV1Capability = 'app_server_status_v1';
const bridgeIdentityV2Capability = 'bridge_identity_v2';
const conversationRuntimeOverlayCapability = 'conversation_runtime_overlay_v1';

const _conversationSyncMaxCatalogChanges = 512;
const _conversationSyncMaxStatuses = 512;
const _conversationSyncMaxThreadStates = 512;
const _conversationSyncMaxPageEntries = 64;
const _conversationSyncMaxPageCount = 4096;
const _conversationSyncMaxTimelineCount = 10000;
const _conversationSyncMaxDataItems = 200;

const LocalFeatureProtocolSlot conversationSyncV2ProtocolSlot =
    _ConversationSyncV2ProtocolSlot();

class _ConversationSyncV2ProtocolSlot implements LocalFeatureProtocolSlot {
  const _ConversationSyncV2ProtocolSlot();

  @override
  String get featureId => 'conversation_sync_v2';

  @override
  List<String> get supportedServerMessageTypes => const [
    conversationSyncV2Capability,
    conversationWindowCoverageCapability,
    conversationRuntimeOverlayCapability,
    conversationUserIndexCapability,
    appServerStatusV1Capability,
  ];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) {
    if (json['type'] != conversationSyncV2Capability) return null;
    return ConversationSyncV2EventMessage.fromJson(json);
  }
}

enum ConversationSyncV2EventKind {
  syncBegin('sync_begin'),
  catalogChanges('catalog_changes'),
  statusChanges('status_changes'),
  timelinePage('timeline_page'),
  runtimeOverlay('runtime_overlay'),
  syncCheckpoint('sync_checkpoint'),
  syncComplete('sync_complete'),
  syncReset('sync_reset'),
  turnsPageResponse('turns_page_response'),
  itemsPageResponse('items_page_response'),
  focusApplied('focus_applied'),
  unsubscribed('unsubscribed'),
  error('error');

  const ConversationSyncV2EventKind(this.wireValue);
  final String wireValue;

  static ConversationSyncV2EventKind parse(Object? value) {
    for (final event in values) {
      if (event.wireValue == value) return event;
    }
    throw FormatException('Unsupported conversation sync event: $value');
  }
}

class ConversationSyncV2Target {
  const ConversationSyncV2Target({
    required this.provider,
    required this.providerSessionId,
  });

  final String provider;
  final String providerSessionId;

  String get key => '$provider\u0000$providerSessionId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'providerSessionId': providerSessionId,
  };

  factory ConversationSyncV2Target.fromJson(Map<String, dynamic> json) =>
      ConversationSyncV2Target(
        provider: _conversationSyncProvider(json['provider']),
        providerSessionId: _conversationSyncString(
          json,
          'providerSessionId',
          maximumLength: 256,
        ),
      );
}

class ConversationSyncV2ThreadState extends ConversationSyncV2Target {
  const ConversationSyncV2ThreadState({
    required super.provider,
    required super.providerSessionId,
    required this.revision,
    this.forceReplacement = false,
  });

  final String revision;
  final bool forceReplacement;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    'revision': revision,
    if (forceReplacement) 'forceReplacement': true,
  };
}

class ConversationSyncV2ReadWatermark extends ConversationSyncV2Target {
  const ConversationSyncV2ReadWatermark({
    required super.provider,
    required super.providerSessionId,
    required this.readAt,
  });

  final String readAt;

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    'readAt': readAt,
  };
}

class ConversationSyncV2CatalogEntry extends ConversationSyncV2Target {
  const ConversationSyncV2CatalogEntry({
    required super.provider,
    required super.providerSessionId,
    required this.revision,
    required this.projectPath,
    required this.createdAt,
    required this.modifiedAt,
    required this.recencyAt,
    required this.availability,
    this.projectGroupKind,
    this.projectGroupId,
    this.projectGroupName,
    this.projectGroupPath,
    this.projectGroupingSnapshotComplete = false,
    this.name,
    this.summary,
    this.firstPrompt,
    this.model,
    this.modelReasoningEffort,
    this.serviceTier,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.sandboxMode,
    this.collaborationMode,
    this.networkAccessEnabled,
    this.webSearchMode,
    this.codexSettingsSnapshotComplete = false,
    this.forkedFromThreadId,
    this.parentThreadId,
  });

  final String revision;
  final String projectPath;
  final String createdAt;
  final String modifiedAt;
  final String recencyAt;
  final String availability;
  final String? projectGroupKind;
  final String? projectGroupId;
  final String? projectGroupName;
  final String? projectGroupPath;
  final bool projectGroupingSnapshotComplete;
  final String? name;
  final String? summary;
  final String? firstPrompt;
  final String? model;
  final String? modelReasoningEffort;
  final String? serviceTier;
  final String? approvalPolicy;
  final String? approvalsReviewer;
  final String? sandboxMode;
  final String? collaborationMode;
  final bool? networkAccessEnabled;
  final String? webSearchMode;
  final bool codexSettingsSnapshotComplete;
  final String? forkedFromThreadId;
  final String? parentThreadId;

  factory ConversationSyncV2CatalogEntry.fromJson(Map<String, dynamic> json) {
    final availability = _conversationSyncString(
      json,
      'availability',
      maximumLength: 16,
    );
    if (availability != 'durable' &&
        availability != 'ephemeral' &&
        availability != 'expired') {
      throw FormatException(
        'Unsupported conversation availability: $availability',
      );
    }
    final projectGroupKind = _conversationSyncProjectGroupKind(
      json['projectGroupKind'],
    );
    final projectGroupId = _conversationSyncOptionalString(
      json,
      'projectGroupId',
      maximumLength: 256,
    );
    final projectGroupName = _conversationSyncOptionalDisplayString(
      json,
      'projectGroupName',
      maximumLength: 512,
    );
    final projectGroupingSnapshotComplete =
        json['projectGroupingSnapshotComplete'] == true &&
        (projectGroupKind == 'projectless' ||
            (projectGroupKind == 'desktopProject' &&
                projectGroupId != null &&
                projectGroupName != null));
    return ConversationSyncV2CatalogEntry(
      provider: _conversationSyncProvider(json['provider']),
      providerSessionId: _conversationSyncString(
        json,
        'providerSessionId',
        maximumLength: 256,
      ),
      revision: _conversationSyncString(json, 'revision', maximumLength: 128),
      projectPath: _conversationSyncString(
        json,
        'projectPath',
        maximumLength: 4096,
        allowEmpty: true,
      ),
      createdAt: _conversationSyncIsoDate(json, 'createdAt'),
      modifiedAt: _conversationSyncIsoDate(json, 'modifiedAt'),
      recencyAt: _conversationSyncIsoDate(json, 'recencyAt'),
      availability: availability,
      projectGroupKind: projectGroupKind,
      projectGroupId: projectGroupId,
      projectGroupName: projectGroupName,
      projectGroupPath: _conversationSyncOptionalString(
        json,
        'projectGroupPath',
        maximumLength: 4096,
      ),
      projectGroupingSnapshotComplete: projectGroupingSnapshotComplete,
      name: _conversationSyncOptionalDisplayString(
        json,
        'name',
        maximumLength: 512,
      ),
      summary: _conversationSyncOptionalDisplayString(
        json,
        'summary',
        maximumLength: 4096,
      ),
      firstPrompt: _conversationSyncOptionalDisplayString(
        json,
        'firstPrompt',
        maximumLength: 4096,
      ),
      model: _conversationSyncOptionalString(json, 'model', maximumLength: 256),
      modelReasoningEffort: _conversationSyncOptionalString(
        json,
        'modelReasoningEffort',
        maximumLength: 64,
      ),
      serviceTier: _conversationSyncOptionalString(
        json,
        'serviceTier',
        maximumLength: 64,
      ),
      approvalPolicy: _conversationSyncOptionalString(
        json,
        'approvalPolicy',
        maximumLength: 64,
      ),
      approvalsReviewer: _conversationSyncOptionalString(
        json,
        'approvalsReviewer',
        maximumLength: 64,
      ),
      sandboxMode: _conversationSyncOptionalString(
        json,
        'sandboxMode',
        maximumLength: 64,
      ),
      collaborationMode: _conversationSyncCollaborationMode(
        json['collaborationMode'],
      ),
      networkAccessEnabled: json['networkAccessEnabled'] is bool
          ? json['networkAccessEnabled'] as bool
          : null,
      webSearchMode: _conversationSyncOptionalString(
        json,
        'webSearchMode',
        maximumLength: 64,
      ),
      codexSettingsSnapshotComplete:
          json['codexSettingsSnapshotComplete'] is bool
          ? json['codexSettingsSnapshotComplete'] as bool
          : false,
      forkedFromThreadId: _conversationSyncOptionalString(
        json,
        'forkedFromThreadId',
        maximumLength: 256,
      ),
      parentThreadId: _conversationSyncOptionalString(
        json,
        'parentThreadId',
        maximumLength: 256,
      ),
    );
  }

  RecentSession toRecentSession({required String codexSourceId}) =>
      RecentSession(
        sessionId: providerSessionId,
        provider: provider,
        codexSourceId: codexSourceId,
        forkedFromThreadId: forkedFromThreadId ?? parentThreadId,
        name: name,
        summary: summary,
        firstPrompt: firstPrompt ?? '',
        created: createdAt,
        modified: recencyAt,
        contentRevision: revision,
        gitBranch: '',
        projectPath: projectPath,
        resumeCwd: projectPath,
        projectGroupKind: projectGroupKind,
        projectGroupId: projectGroupId,
        projectGroupName: projectGroupName,
        projectGroupPath: projectGroupPath,
        projectGroupingSnapshotComplete: projectGroupingSnapshotComplete,
        isSidechain: false,
        codexModel: model,
        codexModelReasoningEffort: modelReasoningEffort,
        codexServiceTier: serviceTier,
        codexApprovalPolicy: approvalPolicy,
        codexApprovalsReviewer: approvalsReviewer,
        codexSandboxMode: sandboxMode,
        codexCollaborationMode: collaborationMode,
        planMode: collaborationMode == 'plan',
        codexNetworkAccessEnabled: networkAccessEnabled,
        codexWebSearchMode: webSearchMode,
        codexSettingsSnapshotComplete: codexSettingsSnapshotComplete,
      );
}

String? _conversationSyncCollaborationMode(Object? value) =>
    value == 'plan' || value == 'default' ? value as String : null;

String? _conversationSyncProjectGroupKind(Object? value) =>
    value == 'desktopProject' || value == 'projectless'
    ? value as String
    : null;

class ConversationSyncV2Status extends ConversationSyncV2Target {
  const ConversationSyncV2Status({
    required super.provider,
    required super.providerSessionId,
    required this.activity,
    required this.attention,
    required this.result,
    required this.runtimeAttachment,
    required this.source,
    required this.confidence,
    required this.observedAt,
    this.attentionRequestId,
    this.executionHost,
    this.activeTurnId,
    this.controlState,
    this.authorityGeneration,
  });

  final String activity;
  final String attention;
  final String result;
  final String runtimeAttachment;
  final String source;
  final String confidence;
  final String observedAt;
  final String? attentionRequestId;

  /// Confirmed origin of the currently active turn.
  ///
  /// This is deliberately independent from [source], which only describes
  /// where the status evidence came from. Older Bridges omit this additive
  /// field and continue through the legacy source fallback in presentation.
  final String? executionHost;

  /// Provider-owned active turn identity used to fence control operations.
  final String? activeTurnId;

  /// Authoritative mutation capability for the active turn.
  ///
  /// Missing means an older Bridge, not writable. Callers must fail closed for
  /// unknown/read-only states instead of inferring control from [source].
  final String? controlState;

  /// Opaque authority epoch paired with [activeTurnId] and [controlState].
  final String? authorityGeneration;

  factory ConversationSyncV2Status.fromJson(Map<String, dynamic> json) {
    final status = ConversationSyncV2Status(
      provider: _conversationSyncProvider(json['provider']),
      providerSessionId: _conversationSyncString(
        json,
        'providerSessionId',
        maximumLength: 256,
      ),
      activity: _conversationSyncString(json, 'activity', maximumLength: 32),
      attention: _conversationSyncString(json, 'attention', maximumLength: 32),
      result: _conversationSyncString(json, 'result', maximumLength: 32),
      runtimeAttachment: _conversationSyncString(
        json,
        'runtimeAttachment',
        maximumLength: 32,
      ),
      source: _conversationSyncString(json, 'source', maximumLength: 32),
      confidence: _conversationSyncString(
        json,
        'confidence',
        maximumLength: 32,
      ),
      observedAt: _conversationSyncIsoDate(json, 'observedAt'),
      attentionRequestId: _conversationSyncOptionalString(
        json,
        'attentionRequestId',
        maximumLength: 256,
      ),
      executionHost: _conversationSyncOptionalString(
        json,
        'executionHost',
        maximumLength: 32,
      ),
      activeTurnId: _conversationSyncOptionalString(
        json,
        'activeTurnId',
        maximumLength: 256,
      ),
      controlState: _conversationSyncOptionalString(
        json,
        'controlState',
        maximumLength: 32,
      ),
      authorityGeneration: _conversationSyncOptionalString(
        json,
        'authorityGeneration',
        maximumLength: 256,
      ),
    );
    if (!const {
          'idle',
          'working',
          'compacting',
          'systemError',
          'unknown',
        }.contains(status.activity) ||
        !const {
          'none',
          'approval',
          'question',
          'permission',
          'form',
        }.contains(status.attention) ||
        !const {'none', 'completed', 'failed'}.contains(status.result) ||
        !const {
          'notLoaded',
          'loaded',
          'ownedElsewhere',
        }.contains(status.runtimeAttachment) ||
        !const {
          'appServer',
          'bridgeRuntime',
          'legacyRollout',
        }.contains(status.source) ||
        !const {
          'authoritative',
          'observed',
          'inferred',
          'unknown',
        }.contains(status.confidence) ||
        (status.executionHost != null &&
            !const {
              'bridge',
              'desktopAppServer',
              'unknown',
            }.contains(status.executionHost)) ||
        (status.controlState != null &&
            !const {
              'readOnly',
              'steerable',
              'writable',
              'reconciling',
              'blocked',
              'unavailable',
            }.contains(status.controlState))) {
      throw const FormatException('Conversation sync status is unsupported.');
    }
    return status;
  }

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...super.toJson(),
    'activity': activity,
    'attention': attention,
    'result': result,
    'runtimeAttachment': runtimeAttachment,
    'source': source,
    'confidence': confidence,
    'observedAt': observedAt,
    'attentionRequestId': ?attentionRequestId,
    'executionHost': ?executionHost,
    'activeTurnId': ?activeTurnId,
    'controlState': ?controlState,
    'authorityGeneration': ?authorityGeneration,
  };
}

class ConversationSyncV2NextState {
  const ConversationSyncV2NextState({
    required this.catalogState,
    required this.statusState,
    required this.threadContentStates,
  });

  final String catalogState;
  final String statusState;
  final List<ConversationSyncV2ThreadState> threadContentStates;
}

class ConversationSyncV2EventMessage implements LocalFeatureTransientMessage {
  const ConversationSyncV2EventMessage({
    required this.event,
    required this.subscriptionId,
    required this.bridgeInstanceId,
    required this.codexSourceId,
    required this.batchId,
    required this.sequence,
    this.requestId,
    this.catalogState,
    this.statusState,
    this.pageIndex,
    this.pageCount,
    this.created = const [],
    this.updated = const [],
    this.destroyed = const [],
    this.statusChanges = const [],
    this.provider,
    this.providerSessionId,
    this.revision,
    this.baseRevision,
    this.mode,
    this.timelineIndex,
    this.timelineCount,
    this.entries = const [],
    this.deletes = const [],
    this.hasEarlier,
    this.turnsNextCursor,
    this.windowComplete,
    this.latestTurnComplete,
    this.latestTurnGap,
    this.sourceEntryCount,
    this.overlayId,
    this.observedAt,
    this.originGeneration,
    this.runtimeSessionId,
    this.authorityGeneration,
    this.overlayMessage,
    this.phase,
    this.hasMore,
    this.nextState,
    this.scope,
    this.reason,
    this.target,
    this.turnId,
    this.data = const [],
    this.nextCursor,
    this.pageComplete,
    this.focused,
    this.errorCode,
    this.error,
  });

  @override
  String get featureId => 'conversation_sync_v2';

  final ConversationSyncV2EventKind event;
  final String subscriptionId;
  final String bridgeInstanceId;
  final String codexSourceId;
  final String batchId;
  final int sequence;
  final String? requestId;
  final String? catalogState;
  final String? statusState;
  final int? pageIndex;
  final int? pageCount;
  final List<ConversationSyncV2CatalogEntry> created;
  final List<ConversationSyncV2CatalogEntry> updated;
  final List<ConversationSyncV2Target> destroyed;
  final List<ConversationSyncV2Status> statusChanges;
  final String? provider;
  final String? providerSessionId;
  final String? revision;
  final String? baseRevision;
  final String? mode;
  final int? timelineIndex;
  final int? timelineCount;
  final List<ConversationContentWireEntry> entries;
  final List<String> deletes;
  final bool? hasEarlier;
  final String? turnsNextCursor;
  final bool? windowComplete;
  final bool? latestTurnComplete;
  final ConversationSyncV2LatestTurnGap? latestTurnGap;
  final int? sourceEntryCount;
  final String? overlayId;
  final String? observedAt;
  final String? originGeneration;
  final String? runtimeSessionId;
  final String? authorityGeneration;
  final ServerMessage? overlayMessage;
  final String? phase;
  final bool? hasMore;
  final ConversationSyncV2NextState? nextState;
  final String? scope;
  final String? reason;
  final ConversationSyncV2Target? target;
  final String? turnId;
  final List<Object?> data;
  final String? nextCursor;
  final bool? pageComplete;
  final ConversationSyncV2Target? focused;
  final String? errorCode;
  final String? error;

  /// Whole-window replacement authority. Older Bridges did not send the
  /// explicit field, so a latest-turn repair is conservatively additive.
  bool get effectiveWindowComplete => windowComplete ?? false;

  @override
  String? get sessionId => providerSessionId ?? target?.providerSessionId;

  List<Map<String, dynamic>> pageRawMessages() {
    final messages = <Map<String, dynamic>>[];
    if (event == ConversationSyncV2EventKind.turnsPageResponse) {
      for (final rawTurn in data) {
        if (rawTurn is! Map) {
          throw const FormatException('Conversation turn page is malformed.');
        }
        final rawMessages = rawTurn['messages'];
        if (rawMessages is! List) {
          throw const FormatException(
            'Conversation turn messages are malformed.',
          );
        }
        for (final rawMessage in rawMessages) {
          if (rawMessage is! Map) {
            throw const FormatException(
              'Conversation page message is malformed.',
            );
          }
          final message = Map<String, dynamic>.from(rawMessage);
          ServerMessage.fromJson(message);
          messages.add(Map.unmodifiable(message));
        }
      }
      return List.unmodifiable(messages);
    }
    if (event == ConversationSyncV2EventKind.itemsPageResponse) {
      for (final rawMessage in data) {
        if (rawMessage is! Map) {
          throw const FormatException(
            'Conversation item page message is malformed.',
          );
        }
        final message = Map<String, dynamic>.from(rawMessage);
        ServerMessage.fromJson(message);
        messages.add(Map.unmodifiable(message));
      }
      return List.unmodifiable(messages);
    }
    return const [];
  }

  factory ConversationSyncV2EventMessage.fromJson(Map<String, dynamic> json) {
    final event = ConversationSyncV2EventKind.parse(json['event']);
    final rawCreated = _conversationSyncList(
      json['created'],
      maximumLength: _conversationSyncMaxCatalogChanges,
    );
    final rawUpdated = _conversationSyncList(
      json['updated'],
      maximumLength: _conversationSyncMaxCatalogChanges,
    );
    final rawDestroyed = _conversationSyncList(
      json['destroyed'],
      maximumLength: _conversationSyncMaxCatalogChanges,
    );
    final rawStatuses = _conversationSyncList(
      json['changes'],
      maximumLength: _conversationSyncMaxStatuses,
    );
    final rawEntries = _conversationSyncList(
      json['entries'],
      maximumLength: _conversationSyncMaxPageEntries,
    );
    final rawDeletes = _conversationSyncList(
      json['deletes'],
      maximumLength: _conversationSyncMaxPageEntries,
    );
    final rawData = _conversationSyncList(
      json['data'],
      maximumLength: _conversationSyncMaxDataItems,
    );
    final message = ConversationSyncV2EventMessage(
      event: event,
      subscriptionId: _conversationSyncString(
        json,
        'subscriptionId',
        maximumLength: 128,
      ),
      bridgeInstanceId: _conversationSyncString(
        json,
        'bridgeInstanceId',
        maximumLength: 256,
      ),
      codexSourceId: _conversationSyncString(
        json,
        'codexSourceId',
        maximumLength: 256,
      ),
      batchId: _conversationSyncString(json, 'batchId', maximumLength: 128),
      sequence: _conversationSyncInt(json, 'sequence', minimum: 0),
      requestId: _conversationSyncOptionalString(
        json,
        'requestId',
        maximumLength: 128,
      ),
      catalogState: _conversationSyncOptionalString(
        json,
        'catalogState',
        maximumLength: 256,
      ),
      statusState: _conversationSyncOptionalString(
        json,
        'statusState',
        maximumLength: 256,
      ),
      pageIndex: _conversationSyncOptionalInt(json, 'pageIndex', minimum: 0),
      pageCount: _conversationSyncOptionalInt(
        json,
        'pageCount',
        minimum: 1,
        maximum: _conversationSyncMaxPageCount,
      ),
      created: _conversationSyncMapList(
        rawCreated,
        ConversationSyncV2CatalogEntry.fromJson,
      ),
      updated: _conversationSyncMapList(
        rawUpdated,
        ConversationSyncV2CatalogEntry.fromJson,
      ),
      destroyed: _conversationSyncMapList(
        rawDestroyed,
        ConversationSyncV2Target.fromJson,
      ),
      statusChanges: _conversationSyncMapList(
        rawStatuses,
        ConversationSyncV2Status.fromJson,
      ),
      provider: _conversationSyncOptionalProvider(json['provider']),
      providerSessionId: _conversationSyncOptionalString(
        json,
        'providerSessionId',
        maximumLength: 256,
      ),
      revision: _conversationSyncOptionalString(
        json,
        'revision',
        maximumLength: 128,
      ),
      baseRevision: _conversationSyncOptionalString(
        json,
        'baseRevision',
        maximumLength: 128,
      ),
      mode: _conversationSyncOptionalString(json, 'mode', maximumLength: 16),
      timelineIndex: _conversationSyncOptionalInt(
        json,
        'timelineIndex',
        minimum: 0,
      ),
      timelineCount: _conversationSyncOptionalInt(
        json,
        'timelineCount',
        minimum: 1,
        maximum: _conversationSyncMaxTimelineCount,
      ),
      entries: _conversationSyncMapList(
        rawEntries,
        ConversationContentWireEntry.fromJson,
      ),
      deletes: List<String>.unmodifiable(
        rawDeletes.map((value) {
          if (value is! String || value.isEmpty || value.length > 512) {
            throw const FormatException(
              'Conversation sync delete id is invalid.',
            );
          }
          return value;
        }),
      ),
      hasEarlier: json['hasEarlier'] as bool?,
      turnsNextCursor: _conversationSyncOptionalString(
        json,
        'turnsNextCursor',
        maximumLength: 512,
      ),
      windowComplete: _conversationSyncOptionalBool(json, 'windowComplete'),
      latestTurnComplete: _conversationSyncOptionalBool(
        json,
        'latestTurnComplete',
      ),
      latestTurnGap: _conversationSyncOptionalLatestTurnGap(
        json['latestTurnGap'],
      ),
      sourceEntryCount: _conversationSyncOptionalInt(
        json,
        'sourceEntryCount',
        minimum: 0,
      ),
      overlayId: _conversationSyncOptionalString(
        json,
        'overlayId',
        maximumLength: 128,
      ),
      observedAt: _conversationSyncOptionalIsoDate(json['observedAt']),
      originGeneration: _conversationSyncOptionalString(
        json,
        'originGeneration',
        maximumLength: 256,
      ),
      runtimeSessionId: _conversationSyncOptionalString(
        json,
        'runtimeSessionId',
        maximumLength: 256,
      ),
      authorityGeneration: _conversationSyncOptionalString(
        json,
        'authorityGeneration',
        maximumLength: 256,
      ),
      overlayMessage: _conversationSyncRuntimeOverlayMessage(json['message']),
      phase: _conversationSyncOptionalString(json, 'phase', maximumLength: 16),
      hasMore: json['hasMore'] as bool?,
      nextState: _conversationSyncNextState(json['nextState']),
      scope: _conversationSyncOptionalString(json, 'scope', maximumLength: 16),
      reason: _conversationSyncOptionalString(
        json,
        'reason',
        maximumLength: 256,
      ),
      target: _conversationSyncOptionalTarget(json['target']),
      turnId: _conversationSyncOptionalString(
        json,
        'turnId',
        maximumLength: 256,
      ),
      data: List<Object?>.unmodifiable(rawData),
      nextCursor: _conversationSyncOptionalString(
        json,
        'nextCursor',
        maximumLength: 512,
      ),
      pageComplete: _conversationSyncOptionalBool(json, 'pageComplete'),
      focused: _conversationSyncOptionalTarget(json['focused']),
      errorCode: _conversationSyncOptionalString(
        json,
        'errorCode',
        maximumLength: 128,
      ),
      error: _conversationSyncOptionalString(
        json,
        'error',
        maximumLength: 2048,
      ),
    );
    _validateConversationSyncEvent(message);
    return message;
  }
}

class ConversationSyncV2LatestTurnGap {
  const ConversationSyncV2LatestTurnGap({
    required this.missingEntryCount,
    required this.payloadOmitted,
    required this.repair,
    this.turnId,
    this.firstMissingSourceIndex,
  });

  final String? turnId;
  final int missingEntryCount;
  final bool payloadOmitted;
  final int? firstMissingSourceIndex;
  final String repair;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'turnId': ?turnId,
    'missingEntryCount': missingEntryCount,
    'payloadOmitted': payloadOmitted,
    'firstMissingSourceIndex': ?firstMissingSourceIndex,
    'repair': repair,
  };

  factory ConversationSyncV2LatestTurnGap.fromJson(Map<String, dynamic> json) {
    final gap = ConversationSyncV2LatestTurnGap(
      turnId: _conversationSyncOptionalString(
        json,
        'turnId',
        maximumLength: 256,
      ),
      missingEntryCount: _conversationSyncInt(
        json,
        'missingEntryCount',
        minimum: 0,
      ),
      payloadOmitted: _conversationSyncBool(json, 'payloadOmitted'),
      firstMissingSourceIndex: _conversationSyncOptionalInt(
        json,
        'firstMissingSourceIndex',
        minimum: 0,
      ),
      repair: _conversationSyncString(json, 'repair', maximumLength: 16),
    );
    if (!const {'items_page', 'turns_page'}.contains(gap.repair) ||
        (gap.repair == 'items_page' && gap.turnId == null)) {
      throw const FormatException(
        'Conversation sync latest turn repair is invalid.',
      );
    }
    return gap;
  }
}

ClientMessage conversationSyncV2Subscribe({
  required String requestId,
  String? catalogState,
  String? statusState,
  required List<ConversationSyncV2ThreadState> threadContentStates,
  required List<ConversationSyncV2ReadWatermark> readWatermarks,
  ConversationSyncV2Target? focused,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_sync_subscribe',
  'protocolVersion': 2,
  'requestId': requestId,
  'catalogState': ?catalogState,
  'statusState': ?statusState,
  'threadContentStates': threadContentStates
      .take(_conversationSyncMaxThreadStates)
      .map((state) => state.toJson())
      .toList(growable: false),
  'readWatermarks': readWatermarks
      .take(_conversationSyncMaxThreadStates)
      .map((watermark) => watermark.toJson())
      .toList(growable: false),
  'focused': ?focused?.toJson(),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2Ack({
  required String subscriptionId,
  required int sequence,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_sync_ack',
  'protocolVersion': 2,
  'subscriptionId': subscriptionId,
  'sequence': sequence,
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2Read({
  required String subscriptionId,
  required ConversationSyncV2ReadWatermark watermark,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_sync_read',
  'protocolVersion': 2,
  'subscriptionId': subscriptionId,
  ...watermark.toJson(),
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2Focus({
  required String requestId,
  required String subscriptionId,
  ConversationSyncV2Target? focused,
  bool refresh = false,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_sync_focus',
  'protocolVersion': 2,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
  'focused': ?focused?.toJson(),
  if (refresh) 'refresh': true,
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2Unsubscribe({
  required String requestId,
  required String subscriptionId,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_sync_unsubscribe',
  'protocolVersion': 2,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2TurnsPage({
  required String requestId,
  required String subscriptionId,
  required ConversationSyncV2Target target,
  String? cursor,
  int limit = 5,
  String sortDirection = 'desc',
  String itemsView = 'summary',
  String? projection,
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_turns_page',
  'protocolVersion': 2,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
  ...target.toJson(),
  'cursor': ?cursor,
  'limit': limit.clamp(1, 200),
  'sortDirection': sortDirection,
  'itemsView': itemsView,
  'projection': ?projection,
}, delivery: ClientMessageDelivery.ephemeral);

ClientMessage conversationSyncV2ItemsPage({
  required String requestId,
  required String subscriptionId,
  required ConversationSyncV2Target target,
  String? turnId,
  List<String>? toolUseIds,
  String? cursor,
  int limit = 200,
  String sortDirection = 'asc',
}) => ClientMessage._(<String, dynamic>{
  'type': 'conversation_items_page',
  'protocolVersion': 2,
  'requestId': requestId,
  'subscriptionId': subscriptionId,
  ...target.toJson(),
  'turnId': ?turnId,
  if (toolUseIds != null)
    'toolUseIds': toolUseIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(8)
        .toList(growable: false),
  'cursor': ?cursor,
  'limit': limit.clamp(1, 200),
  'sortDirection': sortDirection,
}, delivery: ClientMessageDelivery.ephemeral);

void _validateConversationSyncEvent(ConversationSyncV2EventMessage message) {
  final targetComplete =
      (message.provider == null) == (message.providerSessionId == null);
  if (!targetComplete) {
    throw const FormatException('Conversation sync target is incomplete.');
  }
  final validPage =
      message.pageIndex != null &&
      message.pageCount != null &&
      message.pageIndex! < message.pageCount!;
  switch (message.event) {
    case ConversationSyncV2EventKind.syncBegin:
      if (message.requestId == null ||
          message.catalogState == null ||
          message.statusState == null) {
        throw const FormatException('Conversation sync begin is incomplete.');
      }
    case ConversationSyncV2EventKind.catalogChanges:
      if (!validPage || message.catalogState == null) {
        throw const FormatException('Catalog changes are incomplete.');
      }
    case ConversationSyncV2EventKind.statusChanges:
      if (!validPage || message.statusState == null) {
        throw const FormatException('Status changes are incomplete.');
      }
    case ConversationSyncV2EventKind.timelinePage:
      final timelinePositionComplete =
          (message.timelineIndex == null) == (message.timelineCount == null);
      final timelinePositionValid =
          (message.timelineIndex == null && message.timelineCount == null) ||
          (message.timelineIndex != null &&
              message.timelineCount != null &&
              message.timelineIndex! < message.timelineCount!);
      final latestTurnMetadataValid =
          (message.latestTurnComplete == null &&
              message.latestTurnGap == null) ||
          (message.latestTurnComplete == true &&
              message.latestTurnGap == null) ||
          (message.latestTurnComplete == false &&
              message.latestTurnGap != null);
      final windowMetadataValid =
          !(message.windowComplete == true &&
              message.latestTurnComplete == false);
      if (!validPage ||
          message.provider == null ||
          message.providerSessionId == null ||
          message.revision == null ||
          (message.mode != 'snapshot' && message.mode != 'patch') ||
          (message.mode == 'patch' && message.baseRevision == null) ||
          (message.phase != null &&
              !const {'priority', 'recent', 'cold'}.contains(message.phase)) ||
          message.hasEarlier == null ||
          message.sourceEntryCount == null ||
          !latestTurnMetadataValid ||
          !windowMetadataValid ||
          !timelinePositionComplete ||
          !timelinePositionValid) {
        throw const FormatException('Timeline page is incomplete.');
      }
    case ConversationSyncV2EventKind.runtimeOverlay:
      if (message.provider != 'codex' ||
          message.providerSessionId == null ||
          message.overlayId == null ||
          message.observedAt == null ||
          message.originGeneration == null ||
          message.overlayMessage == null) {
        throw const FormatException('Runtime overlay is incomplete.');
      }
    case ConversationSyncV2EventKind.syncCheckpoint:
      if (!const {'priority', 'recent', 'cold'}.contains(message.phase) ||
          message.hasMore == null) {
        throw const FormatException('Sync checkpoint is incomplete.');
      }
    case ConversationSyncV2EventKind.syncComplete:
      if (message.nextState == null) {
        throw const FormatException('Sync completion state is missing.');
      }
    case ConversationSyncV2EventKind.syncReset:
      if (!const {'catalog', 'status', 'thread'}.contains(message.scope) ||
          message.reason == null ||
          (message.scope == 'thread' && message.target == null)) {
        throw const FormatException('Sync reset is incomplete.');
      }
    case ConversationSyncV2EventKind.turnsPageResponse:
    case ConversationSyncV2EventKind.itemsPageResponse:
      if (message.requestId == null ||
          message.provider == null ||
          message.providerSessionId == null ||
          (message.pageComplete == false && message.latestTurnGap == null)) {
        throw const FormatException(
          'Conversation page response is incomplete.',
        );
      }
      message.pageRawMessages();
    case ConversationSyncV2EventKind.focusApplied:
    case ConversationSyncV2EventKind.unsubscribed:
      if (message.requestId == null) {
        throw const FormatException(
          'Conversation sync response is incomplete.',
        );
      }
    case ConversationSyncV2EventKind.error:
      if (message.errorCode == null || message.error == null) {
        throw const FormatException('Conversation sync error is incomplete.');
      }
  }
}

ConversationSyncV2NextState? _conversationSyncNextState(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const FormatException('Conversation sync next state must be a map.');
  }
  final json = Map<String, dynamic>.from(raw);
  final rawStates = _conversationSyncList(
    json['threadContentStates'],
    maximumLength: _conversationSyncMaxThreadStates,
  );
  return ConversationSyncV2NextState(
    catalogState: _conversationSyncString(
      json,
      'catalogState',
      maximumLength: 256,
    ),
    statusState: _conversationSyncString(
      json,
      'statusState',
      maximumLength: 256,
    ),
    threadContentStates: _conversationSyncMapList(rawStates, (entry) {
      return ConversationSyncV2ThreadState(
        provider: _conversationSyncProvider(entry['provider']),
        providerSessionId: _conversationSyncString(
          entry,
          'providerSessionId',
          maximumLength: 256,
        ),
        revision: _conversationSyncString(
          entry,
          'revision',
          maximumLength: 128,
        ),
      );
    }),
  );
}

ConversationSyncV2Target? _conversationSyncOptionalTarget(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const FormatException('Conversation sync target must be a map.');
  }
  return ConversationSyncV2Target.fromJson(Map<String, dynamic>.from(raw));
}

ConversationSyncV2LatestTurnGap? _conversationSyncOptionalLatestTurnGap(
  Object? raw,
) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const FormatException(
      'Conversation sync latest turn gap must be a map.',
    );
  }
  return ConversationSyncV2LatestTurnGap.fromJson(
    Map<String, dynamic>.from(raw),
  );
}

List<Object?> _conversationSyncList(Object? raw, {required int maximumLength}) {
  if (raw == null) return const [];
  if (raw is! List || raw.length > maximumLength) {
    throw const FormatException('Conversation sync list is invalid.');
  }
  return raw;
}

List<T> _conversationSyncMapList<T>(
  List<Object?> values,
  T Function(Map<String, dynamic>) decode,
) => List<T>.unmodifiable(
  values.map((value) {
    if (value is! Map) {
      throw const FormatException('Conversation sync entry must be a map.');
    }
    return decode(Map<String, dynamic>.from(value));
  }),
);

String _conversationSyncProvider(Object? value) {
  if (value != 'claude' && value != 'codex') {
    throw FormatException('Unsupported conversation sync provider: $value');
  }
  return value! as String;
}

String? _conversationSyncOptionalProvider(Object? value) =>
    value == null ? null : _conversationSyncProvider(value);

String _conversationSyncString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! String ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maximumLength) {
    throw FormatException('Conversation sync $key is invalid.');
  }
  return value;
}

String? _conversationSyncOptionalString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value == null) return null;
  return _conversationSyncString(json, key, maximumLength: maximumLength);
}

String? _conversationSyncOptionalDisplayString(
  Map<String, dynamic> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('Conversation sync $key is invalid.');
  }
  if (value.length <= maximumLength) return value;
  var end = maximumLength - 1;
  if (end > 0 &&
      _isHighSurrogate(value.codeUnitAt(end - 1)) &&
      _isLowSurrogate(value.codeUnitAt(end))) {
    end -= 1;
  }
  return '${value.substring(0, end)}…';
}

bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;

bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;

int _conversationSyncInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
  int? maximum,
}) {
  final value = json[key];
  if (value is! int ||
      value < minimum ||
      (maximum != null && value > maximum)) {
    throw FormatException('Conversation sync $key is invalid.');
  }
  return value;
}

int? _conversationSyncOptionalInt(
  Map<String, dynamic> json,
  String key, {
  required int minimum,
  int? maximum,
}) {
  if (json[key] == null) return null;
  return _conversationSyncInt(json, key, minimum: minimum, maximum: maximum);
}

bool _conversationSyncBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw FormatException('Conversation sync $key is invalid.');
  }
  return value;
}

bool? _conversationSyncOptionalBool(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _conversationSyncBool(json, key);
}

String _conversationSyncIsoDate(Map<String, dynamic> json, String key) {
  final value = _conversationSyncString(json, key, maximumLength: 64);
  if (DateTime.tryParse(value) == null) {
    throw FormatException('Conversation sync $key is not an ISO date.');
  }
  return value;
}

String? _conversationSyncOptionalIsoDate(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.length > 64 || DateTime.tryParse(raw) == null) {
    throw const FormatException(
      'Conversation sync optional ISO date is invalid.',
    );
  }
  return raw;
}

ServerMessage? _conversationSyncRuntimeOverlayMessage(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw const FormatException('Conversation runtime overlay is malformed.');
  }
  final message = ServerMessage.fromJson(Map<String, dynamic>.from(raw));
  if (message is ResultMessage ||
      message is ErrorMessage ||
      message is GuardianApprovalMessage ||
      message is ToolUseSummaryMessage) {
    return message;
  }
  throw const FormatException(
    'Conversation runtime overlay type is unsupported.',
  );
}
