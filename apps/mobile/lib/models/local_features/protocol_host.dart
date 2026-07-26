part of '../messages.dart';

abstract interface class LocalFeatureServerMessage implements ServerMessage {
  String get featureId;
  String? get sessionId;
}

abstract interface class LocalFeatureTransientMessage
    implements LocalFeatureServerMessage {}

abstract interface class LocalFeatureProtocolSlot {
  String get featureId;
  List<String> get supportedServerMessageTypes;
  ServerMessage? tryDecode(Map<String, dynamic> json);
}

/// The bounded correlation metadata retained for one local-feature request.
///
/// This deliberately excludes the original request payload. In particular,
/// large or sensitive fields such as side-chat text must never be retained by
/// the compatibility registry in [BridgeService].
class LocalFeatureRequestDescriptor {
  final String featureId;
  final String requestType;
  final String ownerSessionId;
  final String? requestId;

  const LocalFeatureRequestDescriptor({
    required this.featureId,
    required this.requestType,
    required this.ownerSessionId,
    this.requestId,
  });

  /// A payload-free representation used by foundation diagnostics and tests.
  Map<String, Object?> get metadata => <String, Object?>{
    'featureId': featureId,
    'requestType': requestType,
    'ownerSessionId': ownerSessionId,
    'requestId': requestId,
  };
}

/// Optional request-correlation behavior for a local-feature protocol slot.
///
/// Existing [LocalFeatureProtocolSlot] implementations remain source
/// compatible. A feature opts into old-Bridge generic-error isolation only by
/// implementing this second interface and describing its own request and
/// terminal-response contract.
abstract interface class LocalFeatureRequestProtocolSlot {
  LocalFeatureRequestDescriptor? describeRequest(Map<String, dynamic> request);

  bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response,
  );

  /// Matches feature-specific generic errors, including negotiated capability
  /// failures where the wire error does not carry correlation fields.
  ///
  /// `unsupported_message` is matched centrally and exactly by request type;
  /// slots should use this hook only for their own additional error contracts.
  bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error,
  );
}

/// A generic old-Bridge failure correlated back to one local feature request.
///
/// This message is transient infrastructure state. [BridgeService] publishes
/// it only on the dedicated local-feature stream owned by [sessionId].
class LocalFeatureRequestErrorMessage implements LocalFeatureTransientMessage {
  @override
  final String featureId;
  final String ownerSessionId;
  final String requestType;
  final String? requestId;
  final String message;
  final String? errorCode;

  const LocalFeatureRequestErrorMessage({
    required this.featureId,
    required this.ownerSessionId,
    required this.requestType,
    required this.message,
    this.requestId,
    this.errorCode,
  });

  @override
  String get sessionId => ownerSessionId;
}

class DisabledLocalFeatureProtocolSlot implements LocalFeatureProtocolSlot {
  @override
  final String featureId;

  const DisabledLocalFeatureProtocolSlot(this.featureId);

  @override
  List<String> get supportedServerMessageTypes => const [];

  @override
  ServerMessage? tryDecode(Map<String, dynamic> json) => null;
}

class LocalFeatureProtocolHost {
  static const List<LocalFeatureProtocolSlot> _slots = [
    autoApprovalProtocolSlot,
    sessionInsightsProtocolSlot,
    subagentsProtocolSlot,
    addToConversationProtocolSlot,
    sideChatProtocolSlot,
    persistedSideChatProtocolSlot,
    ephemeralSideChatProtocolSlot,
    conversationMirrorProtocolSlot,
    codexCoreActionsProtocolSlot,
    codexDesktopContinuityProtocolSlot,
    fileTransferProtocolSlot,
    fileBrowserProtocolSlot,
    conversationContentProtocolSlot,
  ];

  static List<String> get supportedServerMessageTypes => List.unmodifiable(
    _slots.expand((slot) => slot.supportedServerMessageTypes).toSet(),
  );

  static ServerMessage? tryDecode(Map<String, dynamic> json) {
    final type = json['type'];
    if (type is! String) return null;
    for (final slot in _slots) {
      if (!slot.supportedServerMessageTypes.contains(type)) continue;
      final decoded = slot.tryDecode(json);
      if (decoded == null) {
        throw FormatException(
          'Invalid local feature message for ${slot.featureId}: $type',
        );
      }
      return decoded;
    }
    return null;
  }

  static LocalFeatureRequestDescriptor? describeRequest(
    ClientMessage message, {
    Iterable<LocalFeatureProtocolSlot>? protocolSlots,
  }) {
    if (message.delivery != ClientMessageDelivery.ephemeral) return null;
    final decoded = jsonDecode(message.toJson());
    if (decoded is! Map<String, dynamic>) return null;
    final requestType = decoded['type'];
    if (requestType is! String || requestType.isEmpty) return null;

    for (final slot in protocolSlots ?? _slots) {
      if (slot is! LocalFeatureRequestProtocolSlot) continue;
      final requestSlot = slot as LocalFeatureRequestProtocolSlot;
      final descriptor = requestSlot.describeRequest(decoded);
      if (!_isValidDescriptor(descriptor, slot, requestType)) continue;
      return descriptor;
    }
    return null;
  }

  static bool matchesTerminalResponse(
    LocalFeatureRequestDescriptor request,
    ServerMessage response, {
    Iterable<LocalFeatureProtocolSlot>? protocolSlots,
  }) {
    final slot = _requestSlot(request.featureId, protocolSlots: protocolSlots);
    return slot?.matchesTerminalResponse(request, response) ?? false;
  }

  static bool matchesRequestError(
    LocalFeatureRequestDescriptor request,
    ErrorMessage error, {
    Iterable<LocalFeatureProtocolSlot>? protocolSlots,
  }) {
    final slot = _requestSlot(request.featureId, protocolSlots: protocolSlots);
    return slot?.matchesRequestError(request, error) ?? false;
  }

  static LocalFeatureRequestProtocolSlot? _requestSlot(
    String featureId, {
    Iterable<LocalFeatureProtocolSlot>? protocolSlots,
  }) {
    for (final slot in protocolSlots ?? _slots) {
      if (slot.featureId == featureId &&
          slot is LocalFeatureRequestProtocolSlot) {
        return slot as LocalFeatureRequestProtocolSlot;
      }
    }
    return null;
  }

  static bool _isValidDescriptor(
    LocalFeatureRequestDescriptor? descriptor,
    LocalFeatureProtocolSlot slot,
    String wireRequestType,
  ) {
    if (descriptor == null ||
        descriptor.featureId != slot.featureId ||
        descriptor.requestType != wireRequestType ||
        descriptor.featureId.isEmpty ||
        descriptor.featureId.length > 128 ||
        descriptor.requestType.isEmpty ||
        descriptor.requestType.length > 128 ||
        descriptor.ownerSessionId.trim().isEmpty ||
        descriptor.ownerSessionId.length > 256) {
      return false;
    }
    final requestId = descriptor.requestId;
    return requestId == null ||
        (requestId.trim().isNotEmpty && requestId.length <= 128);
  }

  static ClientMessage ephemeralRequest({
    required String type,
    required String sessionId,
    String? requestId,
    Map<String, dynamic> fields = const {},
  }) {
    return ClientMessage._(<String, dynamic>{
      'type': type,
      'sessionId': sessionId,
      'requestId': ?requestId,
      ...fields,
    }, delivery: ClientMessageDelivery.ephemeral);
  }
}
