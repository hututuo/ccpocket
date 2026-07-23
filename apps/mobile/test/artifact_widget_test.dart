import 'package:ccpocket/l10n/app_localizations.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:ccpocket/widgets/bubbles/artifact_attachment_chip.dart';
import 'package:ccpocket/widgets/bubbles/assistant_bubble.dart';
import 'package:ccpocket/widgets/bubbles/tool_result_bubble.dart';
import 'package:ccpocket/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: AppTheme.darkTheme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

const _preview = ArtifactRef(
  id: 'artifact-preview',
  filename: 'report final.pdf',
  mimeType: 'application/pdf',
  sizeBytes: 2048,
  kind: 'preview',
  source: 'assistant_markdown',
  textContentIndex: 0,
  originalHref: '/Users/me/report final.pdf',
);

const _source = ArtifactRef(
  id: 'artifact-source-safe',
  filename: 'main.dart',
  mimeType: 'text/x-dart',
  sizeBytes: 128,
  kind: 'source',
  source: 'assistant_markdown',
  textContentIndex: 0,
  originalHref: 'lib/main.dart',
  projectRelativePath: 'lib/main.dart',
);

void main() {
  testWidgets('assistant Markdown link opens its matching preview artifact', (
    tester,
  ) async {
    ArtifactRef? opened;
    await tester.pumpWidget(
      _wrap(
        AssistantBubble(
          message: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'message-1',
              role: 'assistant',
              content: [
                ThinkingContent(thinking: 'Checking the file'),
                TextContent(
                  text: '[Open report](/Users/me/report%20final.pdf)',
                ),
              ],
              model: 'codex',
            ),
            artifacts: [_preview],
            artifactContentIndexOffset: 1,
          ),
          onArtifactOpen: (artifact) async => opened = artifact,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('artifact_attachment_artifact-preview')),
      findsNothing,
    );
    await tester.tap(find.text('Open report'));
    await tester.pump();
    expect(opened, _preview);
  });

  testWidgets('a malformed sibling href cannot block a valid preview link', (
    tester,
  ) async {
    const malformed = ArtifactRef(
      id: 'artifact-malformed',
      filename: '100% complete.txt',
      mimeType: 'text/plain',
      sizeBytes: 32,
      kind: 'preview',
      source: 'assistant_markdown',
      textContentIndex: 0,
      originalHref: '/Users/me/100% complete.txt',
    );
    ArtifactRef? opened;
    await tester.pumpWidget(
      _wrap(
        AssistantBubble(
          message: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'message-malformed-sibling',
              role: 'assistant',
              content: [
                TextContent(
                  text: '[Open report](/Users/me/report%20final.pdf)',
                ),
              ],
              model: 'codex',
            ),
            artifacts: [malformed, _preview],
          ),
          onArtifactOpen: (artifact) async => opened = artifact,
        ),
      ),
    );

    await tester.tap(find.text('Open report'));
    await tester.pump();
    expect(opened, _preview);
  });

  testWidgets(
    'local Markdown image renders as an attachment, not a broken image',
    (tester) async {
      const imageArtifact = ArtifactRef(
        id: 'artifact-image',
        filename: 'plot.png',
        mimeType: 'image/png',
        sizeBytes: 512,
        kind: 'preview',
        source: 'assistant_markdown',
        textContentIndex: 0,
        originalHref: '/Users/me/plot.png',
      );
      await tester.pumpWidget(
        _wrap(
          AssistantBubble(
            message: const AssistantServerMessage(
              message: AssistantMessage(
                id: 'message-image',
                role: 'assistant',
                content: [TextContent(text: '![Plot](/Users/me/plot.png)')],
                model: 'codex',
              ),
              artifacts: [imageArtifact],
            ),
            onArtifactOpen: (_) async {},
          ),
        ),
      );

      // The local image is represented once at its original Markdown position.
      expect(find.byType(ArtifactAttachmentChip), findsOneWidget);
      expect(find.text('plot.png'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('tool result exposes a no-href artifact attachment', (
    tester,
  ) async {
    const artifact = ArtifactRef(
      id: 'artifact-tool',
      filename: 'bundle.zip',
      mimeType: 'application/zip',
      sizeBytes: 4096,
      kind: 'preview',
      source: 'structured_tool',
    );
    ArtifactRef? opened;
    await tester.pumpWidget(
      _wrap(
        ToolResultBubble(
          message: const ToolResultMessage(
            toolUseId: 'tool-1',
            content: 'Created bundle',
            artifacts: [artifact],
          ),
          onArtifactOpen: (value) async => opened = value,
        ),
      ),
    );

    expect(find.text('bundle.zip'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tool_result_disclosure')));
    await tester.pump();
    expect(find.text('bundle.zip'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('artifact_attachment_artifact-tool')),
    );
    await tester.pump();
    expect(opened, artifact);
  });

  testWidgets('source waits for artifact validation and never bypasses it', (
    tester,
  ) async {
    ArtifactRef? validationRequest;
    String? directlyOpenedPath;
    await tester.pumpWidget(
      _wrap(
        ToolResultBubble(
          message: const ToolResultMessage(
            toolUseId: 'tool-source-safe',
            content: 'Source',
            artifacts: [_source],
          ),
          onFileTap: (path) => directlyOpenedPath = path,
          onArtifactOpen: (artifact) async => validationRequest = artifact,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('tool_result_disclosure')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('artifact_attachment_artifact-source-safe')),
    );
    await tester.pump();

    expect(validationRequest, _source);
    expect(directlyOpenedPath, isNull);
  });

  testWidgets('plain-text mode keeps linked source attachments visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AssistantBubble(
          message: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'message-source',
              role: 'assistant',
              content: [TextContent(text: '[Source](lib/main.dart)')],
              model: 'codex',
            ),
            artifacts: [_source],
          ),
          onArtifactOpen: (_) async {},
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('artifact_attachment_artifact-source-safe')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('plain_text_toggle')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('artifact_attachment_artifact-source-safe')),
      findsOneWidget,
    );
  });

  testWidgets('plan card and full detail use artifact-aware links', (
    tester,
  ) async {
    const longPlan =
        '# Plan\n\n'
        '[Open report](/Users/me/report%20final.pdf)\n\n'
        '## One\nA\n'
        '## Two\nB\n'
        '## Three\nC\n'
        '## Four\nD\n'
        '## Five\nE\n'
        '## Six\nF';
    ArtifactRef? opened;
    await tester.pumpWidget(
      _wrap(
        AssistantBubble(
          message: const AssistantServerMessage(
            message: AssistantMessage(
              id: 'message-plan',
              role: 'assistant',
              content: [
                TextContent(text: longPlan),
                ToolUseContent(
                  id: 'tool-plan',
                  name: 'ExitPlanMode',
                  input: {'plan': longPlan},
                ),
              ],
              model: 'codex',
            ),
            artifacts: [_preview],
          ),
          onArtifactOpen: (artifact) async => opened = artifact,
        ),
      ),
    );

    await tester.tap(find.text('Open report'));
    await tester.pump();
    expect(opened, _preview);
    expect(
      find.byKey(const ValueKey('artifact_attachment_artifact-preview')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('view_full_plan_button')));
    await tester.pumpAndSettle();
    opened = null;
    await tester.tap(find.text('Open report').last);
    await tester.pump();
    expect(opened, _preview);
  });

  testWidgets('summarized tool result remains visible when it owns artifacts', (
    tester,
  ) async {
    const artifact = ArtifactRef(
      id: 'artifact-summarized',
      filename: 'generated.png',
      mimeType: 'image/png',
      sizeBytes: 4096,
      kind: 'preview',
      source: 'image_generation',
    );
    await tester.pumpWidget(
      _wrap(
        const ServerMessageWidget(
          message: ToolResultMessage(
            toolUseId: 'tool-hidden',
            content: 'Generated',
            artifacts: [artifact],
          ),
          hiddenToolUseIds: {'tool-hidden'},
        ),
      ),
    );

    expect(find.text('generated.png'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tool_result_disclosure')));
    await tester.pump();
    expect(find.text('generated.png'), findsOneWidget);
  });

  testWidgets('summarized view-image result remains available for disclosure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const ServerMessageWidget(
          message: ToolResultMessage(
            toolUseId: 'tool-view-image',
            toolName: 'ViewImage',
            content: 'Viewed image',
            images: [
              ImageRef(
                id: 'image-ref',
                url: '/images/image-ref',
                mimeType: 'image/png',
              ),
            ],
          ),
          httpBaseUrl: 'http://localhost',
          hiddenToolUseIds: {'tool-view-image'},
        ),
      ),
    );

    expect(find.byType(ToolResultBubble), findsOneWidget);
    expect(find.text('Viewed image'), findsOneWidget);
  });

  testWidgets('unsafe source attachment remains disabled', (tester) async {
    const artifact = ArtifactRef(
      id: 'artifact-source',
      filename: 'secret.txt',
      mimeType: 'text/plain',
      sizeBytes: 10,
      kind: 'source',
      source: 'assistant_markdown',
      projectRelativePath: '../secret.txt',
    );
    String? openedPath;
    await tester.pumpWidget(
      _wrap(
        ToolResultBubble(
          message: const ToolResultMessage(
            toolUseId: 'tool-source',
            content: 'Source',
            artifacts: [artifact],
          ),
          onFileTap: (path) => openedPath = path,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('tool_result_disclosure')));
    await tester.pump();
    final inkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const ValueKey('artifact_attachment_artifact-source')),
        matching: find.byType(InkWell),
      ),
    );
    expect(inkWell.onTap, isNull);
    expect(openedPath, isNull);
  });
}
