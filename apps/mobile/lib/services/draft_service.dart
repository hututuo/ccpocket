import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture, compute;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';

typedef DraftImageAttachment = ({Uint8List bytes, String mimeType});
typedef DraftImageListEncoder =
    Future<String> Function(List<DraftImageAttachment> images);
typedef DraftImageListDecoder =
    List<DraftImageAttachment> Function(String value);
typedef PendingSubmissionEncoder =
    Future<String> Function(PendingChatSubmissionDraft submission);
typedef PendingSubmissionDecoder =
    PendingChatSubmissionDraft? Function(String value);

Future<String> _defaultDraftImageListEncoder(
  List<DraftImageAttachment> images,
) {
  final payload = [
    for (final image in images)
      <String, Object>{'bytes': image.bytes, 'mime': image.mimeType},
  ];
  final byteCount = images.fold<int>(
    0,
    (total, image) => total + image.bytes.length,
  );
  if (byteCount <= 64 * 1024) {
    return SynchronousFuture(_encodeDraftImageList(payload));
  }
  return compute(
    _encodeDraftImageList,
    payload,
    debugLabel: 'draft-image-base64',
  );
}

String _encodeDraftImageList(List<Map<String, Object>> images) => jsonEncode([
  for (final image in images)
    {
      'b64': base64Encode(image['bytes']! as Uint8List),
      'mime': image['mime']! as String,
    },
]);

Future<String> _defaultPendingSubmissionEncoder(
  PendingChatSubmissionDraft submission,
) {
  final payload = <String, Object?>{
    'schemaVersion': 2,
    'clientMessageId': submission.clientMessageId,
    'text': submission.text,
    'createdAt': submission.createdAt.toUtc().toIso8601String(),
    'lastAttemptAt': submission.lastAttemptAt?.toUtc().toIso8601String(),
    'attemptCount': submission.attemptCount,
    'lastError': submission.lastError,
    'images': [
      for (final image in submission.images)
        <String, Object>{'bytes': image.bytes, 'mime': image.mimeType},
    ],
    'mentionablePaths': List<String>.of(submission.mentionablePaths),
    'additionalMentions': [
      for (final mention in submission.additionalMentions)
        Map<String, String>.of(mention),
    ],
  };
  final byteCount = submission.images.fold<int>(
    0,
    (total, image) => total + image.bytes.length,
  );
  if (byteCount <= 64 * 1024) {
    return SynchronousFuture(_encodePendingSubmissionPayload(payload));
  }
  return compute(
    _encodePendingSubmissionPayload,
    payload,
    debugLabel: 'pending-submission-base64',
  );
}

String _encodePendingSubmissionPayload(Map<String, Object?> payload) {
  final rawImages = payload['images']! as List;
  return jsonEncode({
    'schemaVersion': payload['schemaVersion'],
    'clientMessageId': payload['clientMessageId'],
    'text': payload['text'],
    'createdAt': payload['createdAt'],
    'lastAttemptAt': payload['lastAttemptAt'],
    'attemptCount': payload['attemptCount'],
    'lastError': payload['lastError'],
    'images': [
      for (final rawImage in rawImages)
        {
          'b64': base64Encode((rawImage as Map)['bytes']! as Uint8List),
          'mime': rawImage['mime']! as String,
        },
    ],
    'mentionablePaths': payload['mentionablePaths'],
    'additionalMentions': payload['additionalMentions'],
  });
}

class PendingChatSubmissionDraft {
  final String clientMessageId;
  final String text;
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  final int attemptCount;
  final String? lastError;
  final List<({Uint8List bytes, String mimeType})> images;
  final List<String> mentionablePaths;
  final List<Map<String, String>> additionalMentions;

  PendingChatSubmissionDraft({
    required this.clientMessageId,
    required this.text,
    DateTime? createdAt,
    this.lastAttemptAt,
    this.attemptCount = 0,
    this.lastError,
    Iterable<({Uint8List bytes, String mimeType})> images = const [],
    Iterable<String> mentionablePaths = const [],
    Iterable<Map<String, String>> additionalMentions = const [],
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       images = List.unmodifiable(images),
       mentionablePaths = List.unmodifiable(mentionablePaths),
       additionalMentions = List.unmodifiable(
         additionalMentions.map(Map<String, String>.unmodifiable),
       );
}

/// Persists unsent chat input text and image attachments per session.
///
/// Uses an in-memory cache for fast reads and writes through to
/// [SharedPreferences] for persistence across app restarts.
class DraftService {
  final SharedPreferences _prefs;
  final DraftImageListEncoder _imageListEncoder;
  final DraftImageListDecoder _imageListDecoder;
  final PendingSubmissionEncoder _pendingSubmissionEncoder;
  final PendingSubmissionDecoder _pendingSubmissionDecoder;
  final Map<String, String> _cache = {};
  final Map<String, List<({Uint8List bytes, String mimeType})>> _imageCache =
      {};
  final Map<String, String> _encodedImageDrafts = {};
  final Map<String, int> _imageWriteGenerations = {};
  final Map<String, PendingChatSubmissionDraft> _pendingSubmissionCache = {};
  final Map<String, String> _encodedPendingSubmissions = {};
  final Map<String, int> _pendingWriteGenerations = {};

  static const _prefix = 'draft_v1_';
  static const _imagePrefix = 'draft_image_v1_';
  static const _pendingSubmissionPrefix = 'draft_pending_submission_v1_';

  DraftService(
    this._prefs, {
    DraftImageListEncoder? imageListEncoder,
    DraftImageListDecoder? imageListDecoder,
    PendingSubmissionEncoder? pendingSubmissionEncoder,
    PendingSubmissionDecoder? pendingSubmissionDecoder,
  }) : _imageListEncoder = imageListEncoder ?? _defaultDraftImageListEncoder,
       _imageListDecoder = imageListDecoder ?? _decodeImageDraftList,
       _pendingSubmissionEncoder =
           pendingSubmissionEncoder ?? _defaultPendingSubmissionEncoder,
       _pendingSubmissionDecoder =
           pendingSubmissionDecoder ?? _decodePendingSubmission {
    _loadAll();
  }

  /// Load all persisted drafts into the memory cache.
  void _loadAll() {
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_pendingSubmissionPrefix)) {
        final sessionId = key.substring(_pendingSubmissionPrefix.length);
        final value = _prefs.getString(key);
        if (value != null && value.isNotEmpty) {
          _encodedPendingSubmissions[sessionId] = value;
        }
      } else if (key.startsWith(_imagePrefix)) {
        final sessionId = key.substring(_imagePrefix.length);
        final value = _prefs.getString(key);
        if (value != null && value.isNotEmpty) {
          _encodedImageDrafts[sessionId] = value;
        }
      } else if (key.startsWith(_prefix)) {
        final sessionId = key.substring(_prefix.length);
        final value = _prefs.getString(key);
        if (value != null && value.isNotEmpty) {
          _cache[sessionId] = value;
        }
      }
    }
  }

  /// Save a draft for the given session.
  ///
  /// If [text] is empty the draft is deleted instead.
  void saveDraft(String sessionId, String text) {
    if (text.isEmpty) {
      deleteDraft(sessionId);
      return;
    }
    _cache[sessionId] = text;
    _prefs.setString('$_prefix$sessionId', text);
  }

  /// Retrieve the draft for [sessionId], or `null` if none exists.
  String? getDraft(String sessionId) => _cache[sessionId];

  /// Remove the draft for [sessionId] (e.g. after a successful send).
  void deleteDraft(String sessionId) {
    _cache.remove(sessionId);
    _prefs.remove('$_prefix$sessionId');
  }

  /// Migrate a draft from [oldId] (e.g. `pending_*`) to [newId].
  ///
  /// This is called when the Bridge Server assigns a real session ID.
  void migrateDraft(String oldId, String newId) {
    final text = _cache[oldId];
    if (text == null) return;
    _cache[newId] = text;
    _prefs.setString('$_prefix$newId', text);
    deleteDraft(oldId);
  }

  /// All cached drafts keyed by session ID.
  Map<String, String> get allDrafts => Map.unmodifiable(_cache);

  // ---------------------------------------------------------------------------
  // Image draft persistence
  // ---------------------------------------------------------------------------

  /// Save image drafts for the given session.
  ///
  /// Stores each image's bytes (Base64-encoded) and MIME type as a JSON array
  /// in [SharedPreferences] so attachments survive navigation.
  void saveImageDraft(
    String sessionId,
    List<({Uint8List bytes, String mimeType})> images,
  ) {
    if (images.isEmpty) {
      deleteImageDraft(sessionId);
      return;
    }
    final snapshot = List<DraftImageAttachment>.unmodifiable(images);
    _imageCache[sessionId] = snapshot;
    _encodedImageDrafts.remove(sessionId);
    final generation = _nextImageWriteGeneration(sessionId);
    unawaited(_persistImageDraft(sessionId, snapshot, generation));
  }

  /// Retrieve the image drafts for [sessionId], or `null` if none exists.
  List<({Uint8List bytes, String mimeType})>? getImageDraft(String sessionId) {
    final cached = _imageCache[sessionId];
    if (cached != null) return cached;
    final encoded = _encodedImageDrafts[sessionId];
    if (encoded == null) return null;
    final decoded = _imageListDecoder(encoded);
    if (decoded.isEmpty) {
      _encodedImageDrafts.remove(sessionId);
      unawaited(_prefs.remove('$_imagePrefix$sessionId'));
      return null;
    }
    final snapshot = List<DraftImageAttachment>.unmodifiable(decoded);
    _imageCache[sessionId] = snapshot;
    return snapshot;
  }

  /// Remove the image draft for [sessionId] (e.g. after sending or clearing).
  void deleteImageDraft(String sessionId) {
    _nextImageWriteGeneration(sessionId);
    _imageCache.remove(sessionId);
    _encodedImageDrafts.remove(sessionId);
    _prefs.remove('$_imagePrefix$sessionId');
  }

  /// Migrate an image draft from [oldId] to [newId].
  void migrateImageDraft(String oldId, String newId) {
    final data = _imageCache[oldId];
    final encoded = _encodedImageDrafts[oldId];
    if (encoded != null) {
      final generation = _nextImageWriteGeneration(newId);
      if (data == null) {
        _imageCache.remove(newId);
      } else {
        _imageCache[newId] = data;
      }
      _encodedImageDrafts[newId] = encoded;
      unawaited(_storeEncodedImageDraft(newId, encoded, generation));
      deleteImageDraft(oldId);
      return;
    }
    if (data != null) {
      saveImageDraft(newId, data);
      deleteImageDraft(oldId);
      return;
    }
  }

  int _nextImageWriteGeneration(String sessionId) {
    final generation = (_imageWriteGenerations[sessionId] ?? 0) + 1;
    _imageWriteGenerations[sessionId] = generation;
    return generation;
  }

  Future<void> _persistImageDraft(
    String sessionId,
    List<DraftImageAttachment> images,
    int generation,
  ) async {
    try {
      final encoded = await _imageListEncoder(images);
      await _storeEncodedImageDraft(sessionId, encoded, generation);
    } catch (error, stackTrace) {
      logger.warning(
        '[draft] Failed to persist image draft for $sessionId',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _storeEncodedImageDraft(
    String sessionId,
    String encoded,
    int generation,
  ) async {
    if (_imageWriteGenerations[sessionId] != generation ||
        (!_imageCache.containsKey(sessionId) &&
            !_encodedImageDrafts.containsKey(sessionId))) {
      return;
    }
    _encodedImageDrafts[sessionId] = encoded;
    final saved = await _prefs.setString('$_imagePrefix$sessionId', encoded);
    if (!saved) {
      throw StateError('SharedPreferences rejected the image draft');
    }
  }

  Future<void> savePendingSubmission(
    String sessionId,
    PendingChatSubmissionDraft submission,
  ) async {
    final existing = getPendingSubmission(sessionId);
    if (existing != null &&
        existing.clientMessageId != submission.clientMessageId) {
      throw StateError('A different submission is already queued');
    }

    final existingEncoded = _encodedPendingSubmissions[sessionId];
    _pendingSubmissionCache[sessionId] = submission;
    _encodedPendingSubmissions.remove(sessionId);
    final generation = _nextPendingWriteGeneration(sessionId);
    try {
      final encoded = await _pendingSubmissionEncoder(submission);
      if (_pendingWriteGenerations[sessionId] != generation) {
        return;
      }
      await _storeEncodedPendingSubmission(sessionId, encoded, generation);
    } catch (error) {
      if (_pendingWriteGenerations[sessionId] != generation) {
        return;
      }
      if (existing == null) {
        _pendingSubmissionCache.remove(sessionId);
      } else {
        _pendingSubmissionCache[sessionId] = existing;
      }
      if (existingEncoded == null) {
        _encodedPendingSubmissions.remove(sessionId);
      } else {
        _encodedPendingSubmissions[sessionId] = existingEncoded;
      }
      rethrow;
    }
  }

  PendingChatSubmissionDraft? getPendingSubmission(String sessionId) {
    final cached = _pendingSubmissionCache[sessionId];
    if (cached != null) return cached;
    final encoded = _encodedPendingSubmissions[sessionId];
    if (encoded == null) return null;
    final decoded = _pendingSubmissionDecoder(encoded);
    if (decoded == null) {
      _encodedPendingSubmissions.remove(sessionId);
      unawaited(_prefs.remove('$_pendingSubmissionPrefix$sessionId'));
      return null;
    }
    _pendingSubmissionCache[sessionId] = decoded;
    return decoded;
  }

  bool deletePendingSubmission(String sessionId, {String? clientMessageId}) {
    final existing = getPendingSubmission(sessionId);
    if (existing == null ||
        (clientMessageId != null &&
            existing.clientMessageId != clientMessageId)) {
      return false;
    }
    _nextPendingWriteGeneration(sessionId);
    _pendingSubmissionCache.remove(sessionId);
    _encodedPendingSubmissions.remove(sessionId);
    _prefs.remove('$_pendingSubmissionPrefix$sessionId');
    return true;
  }

  void migratePendingSubmission(String oldId, String newId) {
    final submission = _pendingSubmissionCache[oldId];
    final encoded = _encodedPendingSubmissions[oldId];
    if (submission == null && encoded == null) return;

    _nextPendingWriteGeneration(oldId);
    _pendingSubmissionCache.remove(oldId);
    _encodedPendingSubmissions.remove(oldId);
    _prefs.remove('$_pendingSubmissionPrefix$oldId');

    final generation = _nextPendingWriteGeneration(newId);
    if (encoded != null) {
      if (submission == null) {
        _pendingSubmissionCache.remove(newId);
      } else {
        _pendingSubmissionCache[newId] = submission;
      }
      _encodedPendingSubmissions[newId] = encoded;
      unawaited(
        _storeEncodedPendingSubmission(newId, encoded, generation).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          logger.warning(
            '[draft] Failed to migrate queued submission to $newId',
            error,
            stackTrace,
          );
        }),
      );
      return;
    }

    _pendingSubmissionCache[newId] = submission!;
    _encodedPendingSubmissions.remove(newId);
    unawaited(_persistPendingSubmission(newId, submission, generation));
  }

  int _nextPendingWriteGeneration(String sessionId) {
    final generation = (_pendingWriteGenerations[sessionId] ?? 0) + 1;
    _pendingWriteGenerations[sessionId] = generation;
    return generation;
  }

  Future<void> _persistPendingSubmission(
    String sessionId,
    PendingChatSubmissionDraft submission,
    int generation,
  ) async {
    try {
      final encoded = await _pendingSubmissionEncoder(submission);
      await _storeEncodedPendingSubmission(sessionId, encoded, generation);
    } catch (error, stackTrace) {
      logger.warning(
        '[draft] Failed to persist migrated submission for $sessionId',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _storeEncodedPendingSubmission(
    String sessionId,
    String encoded,
    int generation,
  ) async {
    if (_pendingWriteGenerations[sessionId] != generation ||
        (!_pendingSubmissionCache.containsKey(sessionId) &&
            !_encodedPendingSubmissions.containsKey(sessionId))) {
      return;
    }
    _encodedPendingSubmissions[sessionId] = encoded;
    final saved = await _prefs.setString(
      '$_pendingSubmissionPrefix$sessionId',
      encoded,
    );
    if (!saved) {
      throw StateError('SharedPreferences rejected the queued submission');
    }
  }

  static PendingChatSubmissionDraft? _decodePendingSubmission(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return null;
      final clientMessageId = decoded['clientMessageId'];
      final text = decoded['text'];
      if (clientMessageId is! String ||
          clientMessageId.trim().isEmpty ||
          text is! String) {
        return null;
      }

      final images = <({Uint8List bytes, String mimeType})>[];
      final rawImages = decoded['images'];
      if (rawImages is List) {
        for (final rawImage in rawImages.take(5)) {
          if (rawImage is! Map) continue;
          final b64 = rawImage['b64'];
          final mime = rawImage['mime'];
          if (b64 is! String || mime is! String || mime.trim().isEmpty) {
            continue;
          }
          images.add((bytes: base64Decode(b64), mimeType: mime));
        }
      }

      final mentionablePaths = <String>[];
      final rawPaths = decoded['mentionablePaths'];
      if (rawPaths is List) {
        for (final rawPath in rawPaths) {
          if (rawPath is String && rawPath.trim().isNotEmpty) {
            mentionablePaths.add(rawPath);
          }
        }
      }

      final additionalMentions = <Map<String, String>>[];
      final rawMentions = decoded['additionalMentions'];
      if (rawMentions is List) {
        for (final rawMention in rawMentions) {
          if (rawMention is! Map) continue;
          final name = rawMention['name'];
          final path = rawMention['path'];
          if (name is String &&
              name.trim().isNotEmpty &&
              path is String &&
              path.trim().isNotEmpty) {
            additionalMentions.add({'name': name, 'path': path});
          }
        }
      }

      final rawCreatedAt = decoded['createdAt'];
      final createdAt = rawCreatedAt is String
          ? DateTime.tryParse(rawCreatedAt)
          : null;
      final rawLastAttemptAt = decoded['lastAttemptAt'];
      final lastAttemptAt = rawLastAttemptAt is String
          ? DateTime.tryParse(rawLastAttemptAt)
          : null;
      final attemptCount = decoded['attemptCount'];
      final lastError = decoded['lastError'];

      return PendingChatSubmissionDraft(
        clientMessageId: clientMessageId,
        text: text,
        // v1 records did not carry lifecycle metadata. Epoch marks them as
        // recovered legacy input without pretending they were created now.
        createdAt:
            createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        lastAttemptAt: lastAttemptAt,
        attemptCount: attemptCount is int && attemptCount >= 0
            ? attemptCount
            : 0,
        lastError: lastError is String && lastError.trim().isNotEmpty
            ? lastError
            : null,
        images: images,
        mentionablePaths: mentionablePaths,
        additionalMentions: additionalMentions,
      );
    } catch (_) {
      return null;
    }
  }

  /// Decode stored image draft string.
  ///
  /// Supports two formats:
  /// - **New** (JSON array): `[{"b64":"...","mime":"..."},...]`
  /// - **Legacy** (single image): `base64|mimeType`
  static List<({Uint8List bytes, String mimeType})> _decodeImageDraftList(
    String value,
  ) {
    // Try JSON array format first.
    if (value.startsWith('[')) {
      try {
        final list = jsonDecode(value) as List;
        return list
            .cast<Map<String, dynamic>>()
            .map(
              (m) => (
                bytes: base64Decode(m['b64'] as String),
                mimeType: m['mime'] as String,
              ),
            )
            .toList();
      } catch (_) {
        return [];
      }
    }
    // Legacy single-image format: `base64|mimeType`.
    final sep = value.lastIndexOf('|');
    if (sep < 0) return [];
    try {
      final bytes = base64Decode(value.substring(0, sep));
      final mimeType = value.substring(sep + 1);
      return [(bytes: bytes, mimeType: mimeType)];
    } catch (_) {
      return [];
    }
  }
}
