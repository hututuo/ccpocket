import 'dart:convert';
import 'dart:io';

import 'package:ccpocket/features/chat_session/state/detached_timeline_projection.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'diagnostic alias sentinel keeps the final reply after duplicate overlays',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/timeline_projection_ccp_1786682680089719.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final providerOrder = (fixture['providerOrder'] as List<dynamic>)
          .cast<String>();
      final pollutedOverlayOrder =
          (fixture['pollutedRuntimeOverlayOrder'] as List<dynamic>)
              .cast<String>();

      ChatEntry assistant(String id) => ServerChatEntry(
        AssistantServerMessage(
          message: AssistantMessage(
            id: id,
            role: 'assistant',
            content: [TextContent(text: 'fixture:$id')],
            model: 'fixture-model',
          ),
          messageUuid: id,
          historyTurnId: 'turn-regression',
        ),
      );

      Iterable<String> aliases(ChatEntry entry) sync* {
        if (entry is UserChatEntry) {
          final clientMessageId = entry.clientMessageId;
          if (clientMessageId != null) yield 'user:client:$clientMessageId';
          return;
        }
        if (entry case ServerChatEntry(
          message: AssistantServerMessage(:final message),
        )) {
          yield 'assistant:id:${message.id}';
        }
      }

      final canonical = <ChatEntry>[
        UserChatEntry(
          'fixture prompt',
          clientMessageId: 'fixture-user',
          status: MessageStatus.sent,
        ),
        ...providerOrder.map(assistant),
      ];
      final result = projectDetachedTimeline(
        canonicalEntries: canonical,
        outgoingOverlays: const [],
        runtimeOverlays: pollutedOverlayOrder.map(assistant).toList(),
        exactAliases: aliases,
        mergeEquivalent: (overlay, canonical) => canonical,
      );

      final projectedProviderOrder = result.entries
          .whereType<ServerChatEntry>()
          .map((entry) => entry.message)
          .whereType<AssistantServerMessage>()
          .map((message) => message.message.id)
          .toList(growable: false);
      expect(
        projectedProviderOrder,
        (fixture['expectedProjectedProviderOrder'] as List<dynamic>)
            .cast<String>(),
      );
      expect(result.entries, hasLength(canonical.length));
      expect(result.duplicateOverlayCount, 2);
      expect(fixture['fixtureScope'], 'alias_sentinel_without_raw_rows');
      // These counts are provenance copied from the unavailable development
      // report, not reducer input and not a claim that this reduced sentinel
      // replays all 697/1,024 captured rows.
      expect(fixture['sqliteCommittedEntryCount'], 697);
      expect(fixture['observedProjectionEntryCounts'], [5268, 1077]);
      expect(
        (fixture['replayedImageSubmission']
            as Map<String, dynamic>)['imageCount'],
        1,
      );
    },
  );
}
