import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture, compute;

typedef DataImageDecoder = Future<Uint8List?> Function(String dataUrl);

const _dataImageMarker = ';base64,';
const _maxCachedDataImages = 8;
const _backgroundDecodeThreshold = 64 * 1024;
final _dataImageDecodeCache = <String, Future<Uint8List?>>{};

bool isDataImageUrl(String url) => url.startsWith('data:image/');

Future<Uint8List?> decodeDataImageUrl(String url) {
  if (!isDataImageUrl(url)) return Future<Uint8List?>.value();
  final cached = _dataImageDecodeCache.remove(url);
  if (cached != null) {
    _dataImageDecodeCache[url] = cached;
    return cached;
  }
  final markerIndex = url.indexOf(_dataImageMarker);
  final encodedLength = markerIndex == -1
      ? 0
      : url.length - markerIndex - _dataImageMarker.length;
  final future = encodedLength <= _backgroundDecodeThreshold
      ? SynchronousFuture<Uint8List?>(_decodeDataImageUrlInBackground(url))
      : compute(
          _decodeDataImageUrlInBackground,
          url,
          debugLabel: 'data-image-base64',
        );
  if (_dataImageDecodeCache.length >= _maxCachedDataImages) {
    _dataImageDecodeCache.remove(_dataImageDecodeCache.keys.first);
  }
  _dataImageDecodeCache[url] = future;
  return future;
}

Uint8List? _decodeDataImageUrlInBackground(String url) {
  final markerIndex = url.indexOf(_dataImageMarker);
  if (markerIndex == -1) return null;
  try {
    return base64Decode(url.substring(markerIndex + _dataImageMarker.length));
  } catch (_) {
    return null;
  }
}
