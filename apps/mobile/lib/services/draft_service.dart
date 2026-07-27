import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class PendingChatSubmissionDraft {
  final String clientMessageId;
  final String text;
  final List<({Uint8List bytes, String mimeType})> images;
  final List<String> mentionablePaths;
  final List<Map<String, String>> additionalMentions;

  PendingChatSubmissionDraft({
    required this.clientMessageId,
    required this.text,
    Iterable<({Uint8List bytes, String mimeType})> images = const [],
    Iterable<String> mentionablePaths = const [],
    Iterable<Map<String, String>> additionalMentions = const [],
  }) : images = List.unmodifiable(images),
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
  final Map<String, String> _cache = {};
  final Map<String, List<({Uint8List bytes, String mimeType})>> _imageCache =
      {};
  final Map<String, PendingChatSubmissionDraft> _pendingSubmissionCache = {};

  static const _prefix = 'draft_v1_';
  static const _imagePrefix = 'draft_image_v1_';
  static const _pendingSubmissionPrefix = 'draft_pending_submission_v1_';

  DraftService(this._prefs) {
    _loadAll();
  }

  /// Load all persisted drafts into the memory cache.
  void _loadAll() {
    for (final key in _prefs.getKeys()) {
      if (key.startsWith(_pendingSubmissionPrefix)) {
        final sessionId = key.substring(_pendingSubmissionPrefix.length);
        final value = _prefs.getString(key);
        final decoded = value == null ? null : _decodePendingSubmission(value);
        if (decoded != null) {
          _pendingSubmissionCache[sessionId] = decoded;
        }
      } else if (key.startsWith(_imagePrefix)) {
        final sessionId = key.substring(_imagePrefix.length);
        final value = _prefs.getString(key);
        if (value != null && value.isNotEmpty) {
          final decoded = _decodeImageDraftList(value);
          if (decoded.isNotEmpty) {
            _imageCache[sessionId] = decoded;
          }
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
    _imageCache[sessionId] = images;
    final jsonList = images
        .map((img) => {'b64': base64Encode(img.bytes), 'mime': img.mimeType})
        .toList();
    _prefs.setString('$_imagePrefix$sessionId', jsonEncode(jsonList));
  }

  /// Retrieve the image drafts for [sessionId], or `null` if none exists.
  List<({Uint8List bytes, String mimeType})>? getImageDraft(String sessionId) =>
      _imageCache[sessionId];

  /// Remove the image draft for [sessionId] (e.g. after sending or clearing).
  void deleteImageDraft(String sessionId) {
    _imageCache.remove(sessionId);
    _prefs.remove('$_imagePrefix$sessionId');
  }

  /// Migrate an image draft from [oldId] to [newId].
  void migrateImageDraft(String oldId, String newId) {
    final data = _imageCache[oldId];
    if (data == null) return;
    _imageCache[newId] = data;
    // Re-encode for the new key.
    final jsonList = data
        .map((img) => {'b64': base64Encode(img.bytes), 'mime': img.mimeType})
        .toList();
    _prefs.setString('$_imagePrefix$newId', jsonEncode(jsonList));
    deleteImageDraft(oldId);
  }

  Future<void> savePendingSubmission(
    String sessionId,
    PendingChatSubmissionDraft submission,
  ) async {
    final existing = _pendingSubmissionCache[sessionId];
    if (existing != null &&
        existing.clientMessageId != submission.clientMessageId) {
      throw StateError('A different submission is already queued');
    }

    final encoded = _encodePendingSubmission(submission);
    _pendingSubmissionCache[sessionId] = submission;
    try {
      final saved = await _prefs.setString(
        '$_pendingSubmissionPrefix$sessionId',
        encoded,
      );
      if (!saved) {
        throw StateError('SharedPreferences rejected the queued submission');
      }
    } catch (_) {
      if (existing == null) {
        _pendingSubmissionCache.remove(sessionId);
      } else {
        _pendingSubmissionCache[sessionId] = existing;
      }
      rethrow;
    }
  }

  PendingChatSubmissionDraft? getPendingSubmission(String sessionId) =>
      _pendingSubmissionCache[sessionId];

  bool deletePendingSubmission(String sessionId, {String? clientMessageId}) {
    final existing = _pendingSubmissionCache[sessionId];
    if (existing == null ||
        (clientMessageId != null &&
            existing.clientMessageId != clientMessageId)) {
      return false;
    }
    _pendingSubmissionCache.remove(sessionId);
    _prefs.remove('$_pendingSubmissionPrefix$sessionId');
    return true;
  }

  void migratePendingSubmission(String oldId, String newId) {
    final submission = _pendingSubmissionCache[oldId];
    if (submission == null) return;
    _pendingSubmissionCache[newId] = submission;
    _prefs.setString(
      '$_pendingSubmissionPrefix$newId',
      _encodePendingSubmission(submission),
    );
    deletePendingSubmission(oldId);
  }

  static String _encodePendingSubmission(
    PendingChatSubmissionDraft submission,
  ) {
    return jsonEncode({
      'clientMessageId': submission.clientMessageId,
      'text': submission.text,
      'images': submission.images
          .map(
            (image) => {
              'b64': base64Encode(image.bytes),
              'mime': image.mimeType,
            },
          )
          .toList(growable: false),
      'mentionablePaths': submission.mentionablePaths,
      'additionalMentions': submission.additionalMentions,
    });
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

      return PendingChatSubmissionDraft(
        clientMessageId: clientMessageId,
        text: text,
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
