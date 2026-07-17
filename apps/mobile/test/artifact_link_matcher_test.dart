import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/utils/artifact_link_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = ArtifactRef(
  id: 'first',
  filename: 'report final.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 10,
  kind: 'preview',
  source: 'assistant_markdown',
  textContentIndex: 0,
  originalHref: '/Users/me/report%20final.pdf',
);

void main() {
  test('matches a single percent-decoded href', () {
    expect(
      matchArtifactHref(
        artifacts: const [_first],
        textContentIndex: 0,
        href: '/Users/me/report final.pdf',
      ),
      _first,
    );
  });

  test('content index disambiguates repeated hrefs', () {
    const second = ArtifactRef(
      id: 'second',
      filename: 'report final.pdf',
      mimeType: 'application/pdf',
      sizeBytes: 10,
      kind: 'preview',
      source: 'assistant_markdown',
      textContentIndex: 2,
      originalHref: '/Users/me/report%20final.pdf',
    );
    expect(
      matchArtifactHref(
        artifacts: const [_first, second],
        textContentIndex: 2,
        href: '/Users/me/report final.pdf',
      )?.id,
      'second',
    );
    expect(
      matchArtifactHref(
        artifacts: const [_first, second],
        textContentIndex: 1,
        href: '/Users/me/report final.pdf',
      ),
      isNull,
    );
  });

  test('does not normalize encoded separators or unsafe source paths', () {
    expect(
      artifactHrefsEquivalent('/Users/me/a%2Fb.pdf', '/Users/me/a/b.pdf'),
      isFalse,
    );
    expect(
      artifactHrefsEquivalent('/root/a%252Fb.pdf', '/root/a%2Fb.pdf'),
      isFalse,
    );
    expect(isSafeProjectRelativePath('lib/main.dart'), isTrue);
    expect(isSafeProjectRelativePath('../secret.txt'), isFalse);
    expect(isSafeProjectRelativePath('%2e%2e/secret.txt'), isFalse);
    expect(isSafeProjectRelativePath('/Users/me/secret.txt'), isFalse);
    expect(isSafeProjectRelativePath(r'C:\secret.txt'), isFalse);
  });

  test('malformed percent escapes cannot break another artifact link', () {
    const malformed = ArtifactRef(
      id: 'malformed',
      filename: '100% complete.txt',
      mimeType: 'text/plain',
      sizeBytes: 10,
      kind: 'preview',
      source: 'assistant_markdown',
      textContentIndex: 0,
      originalHref: '/Users/me/100% complete.txt',
    );

    expect(
      () => artifactHrefsEquivalent(
        malformed.originalHref!,
        '/Users/me/another.txt',
      ),
      returnsNormally,
    );
    expect(
      matchArtifactHref(
        artifacts: const [malformed, _first],
        textContentIndex: 0,
        href: '/Users/me/report final.pdf',
      ),
      _first,
    );
  });

  test('distinguishes local paths from non-file URI schemes', () {
    expect(isLocalFileLikeHref('/Users/me/report.pdf'), isTrue);
    expect(isLocalFileLikeHref('docs/report.pdf'), isTrue);
    expect(isLocalFileLikeHref('file:///Users/me/report.pdf'), isTrue);
    expect(isLocalFileLikeHref(r'C:\report.pdf'), isTrue);
    expect(isLocalFileLikeHref('notes:12'), isTrue);
    expect(isLocalFileLikeHref('notes:12:3'), isTrue);
    expect(isLocalFileLikeHref('mailto:person@example.com'), isFalse);
    expect(isLocalFileLikeHref('tel:+15551234567'), isFalse);
    expect(isLocalFileLikeHref('#section'), isFalse);
  });
}
