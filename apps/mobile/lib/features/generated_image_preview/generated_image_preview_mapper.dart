import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/messages.dart';
import '../../utils/data_image_decode.dart';
import 'generated_image_preview_item.dart';

typedef GeneratedImageItemCacheKey = ({
  String toolUseId,
  String imageId,
  String resolvedUrl,
  String? resolvedThumbnailUrl,
  String mimeType,
  String content,
});

List<GeneratedImagePreviewItem> generatedImageItemsFromToolResults(
  List<ToolResultMessage> messages, {
  required String? httpBaseUrl,
  Map<GeneratedImageItemCacheKey, GeneratedImagePreviewItem>? itemCache,
}) {
  final items = <GeneratedImagePreviewItem>[];
  for (final message in messages) {
    for (var imageIndex = 0; imageIndex < message.images.length; imageIndex++) {
      final image = message.images[imageIndex];
      final resolvedUrl = _resolveImageUrl(image.url, httpBaseUrl);
      if (resolvedUrl == null) continue;
      final resolvedThumbnailUrl = image.thumbnailUrl == null
          ? null
          : _resolveImageUrl(image.thumbnailUrl!, httpBaseUrl);
      final cacheKey = (
        toolUseId: message.toolUseId,
        imageId: image.id,
        resolvedUrl: resolvedUrl,
        resolvedThumbnailUrl: resolvedThumbnailUrl,
        mimeType: image.mimeType,
        content: message.content,
      );
      final cachedItem = itemCache?[cacheKey];
      if (cachedItem != null) {
        items.add(cachedItem);
        continue;
      }
      final item = _itemFromImageRef(
        message: message,
        image: image,
        imageIndex: imageIndex,
        resolvedUrl: resolvedUrl,
        resolvedThumbnailUrl: resolvedThumbnailUrl,
      );
      items.add(item);
      if (itemCache != null) {
        if (itemCache.length >= 64) {
          itemCache.remove(itemCache.keys.first);
        }
        itemCache[cacheKey] = item;
      }
    }
  }
  return items;
}

GeneratedImagePreviewItem _itemFromImageRef({
  required ToolResultMessage message,
  required ImageRef image,
  required int imageIndex,
  required String resolvedUrl,
  required String? resolvedThumbnailUrl,
}) {
  final dataUrl = isDataImageUrl(resolvedUrl) ? resolvedUrl : null;
  return GeneratedImagePreviewItem(
    id: '${message.toolUseId}:${image.id}',
    url: dataUrl == null ? resolvedUrl : null,
    dataUrl: dataUrl,
    thumbnailUrl: dataUrl == null ? resolvedThumbnailUrl : null,
    cacheKey: dataUrl == null
        ? _generatedImageCacheKey(message, imageIndex, image.mimeType)
        : null,
    mimeType: image.mimeType,
    prompt: _readPrefixedLine(message.content, 'revisedPrompt') ?? '',
    status: _readPrefixedLine(message.content, 'status'),
    savedPath: _readPrefixedLine(message.content, 'savedPath'),
    details: message.content.isEmpty ? null : message.content,
  );
}

String _generatedImageCacheKey(
  ToolResultMessage message,
  int imageIndex,
  String mimeType,
) {
  final normalizedImageId = message.images[imageIndex].id.toLowerCase();
  final isContentAddressed = RegExp(
    r'^[0-9a-f]{64}$',
  ).hasMatch(normalizedImageId);
  final identity = isContentAddressed
      ? 'generated-image-content-v1\n$normalizedImageId\n$mimeType'
      : 'generated-image-v1\n'
            '${message.toolUseId}\n'
            '$imageIndex\n'
            '$mimeType';
  return sha256.convert(utf8.encode(identity)).toString();
}

bool canResolveGeneratedImageUrl(
  String imageUrl, {
  required String? httpBaseUrl,
}) {
  return _resolveImageUrl(imageUrl, httpBaseUrl) != null;
}

String? _resolveImageUrl(String imageUrl, String? httpBaseUrl) {
  if (imageUrl.isEmpty) return null;
  final uri = Uri.tryParse(imageUrl);
  if (imageUrl.startsWith('data:image/') || uri?.hasScheme == true) {
    return imageUrl;
  }
  if (httpBaseUrl == null) return null;
  return '$httpBaseUrl$imageUrl';
}

String? _readPrefixedLine(String content, String key) {
  final prefix = '$key:';
  for (final line in content.split('\n')) {
    if (!line.startsWith(prefix)) continue;
    final value = line.substring(prefix.length).trim();
    return value.isEmpty ? null : value;
  }
  return null;
}
