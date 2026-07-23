typedef TextLinePreview = ({String text, bool hasMore});

/// Returns at most [maxLines] leading lines without splitting [content].
///
/// Tool payloads can be several megabytes while their collapsed timeline card
/// shows only five lines. Scanning just far enough to locate that boundary
/// avoids allocating a list containing every line.
TextLinePreview buildTextLinePreview(String content, {required int maxLines}) {
  if (maxLines <= 0) {
    throw ArgumentError.value(maxLines, 'maxLines', 'Must be positive.');
  }

  var searchFrom = 0;
  for (var line = 0; line < maxLines; line++) {
    final newline = content.indexOf('\n', searchFrom);
    if (newline < 0) {
      return (text: content, hasMore: false);
    }
    if (line == maxLines - 1) {
      return (text: content.substring(0, newline), hasMore: true);
    }
    searchFrom = newline + 1;
  }

  return (text: content, hasMore: false);
}
