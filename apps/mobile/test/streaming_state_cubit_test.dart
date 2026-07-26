import 'package:bloc_test/bloc_test.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state.dart';
import 'package:ccpocket/features/chat_session/state/streaming_state_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StreamingStateCubit', () {
    late StreamingStateCubit cubit;

    setUp(() {
      cubit = StreamingStateCubit(coalesceInterval: Duration.zero);
    });

    tearDown(() {
      cubit.close();
    });

    test('initial state has empty text, thinking, and isStreaming false', () {
      expect(cubit.state, const StreamingState());
      expect(cubit.state.text, isEmpty);
      expect(cubit.state.thinking, isEmpty);
      expect(cubit.state.isStreaming, false);
    });

    group('appendText', () {
      blocTest<StreamingStateCubit, StreamingState>(
        'emits accumulated text with isStreaming true',
        build: () => StreamingStateCubit(coalesceInterval: Duration.zero),
        act: (cubit) {
          cubit.appendText('Hello ');
          cubit.appendText('world');
        },
        expect: () => [
          const StreamingState(text: 'Hello ', isStreaming: true),
          const StreamingState(text: 'Hello world', isStreaming: true),
        ],
      );

      test('appends empty string without changing text content', () {
        cubit.appendText('');

        expect(cubit.state.text, isEmpty);
        expect(cubit.state.isStreaming, true);
      });

      test('handles special characters', () {
        cubit.appendText('日本語');
        cubit.appendText(' & <html>');

        expect(cubit.state.text, '日本語 & <html>');
        expect(cubit.state.isStreaming, true);
      });

      test('handles multiline text', () {
        cubit.appendText('line1\n');
        cubit.appendText('line2\n');

        expect(cubit.state.text, 'line1\nline2\n');
      });
    });

    group('appendThinking', () {
      blocTest<StreamingStateCubit, StreamingState>(
        'emits accumulated thinking text as a live stream',
        build: () => StreamingStateCubit(coalesceInterval: Duration.zero),
        act: (cubit) {
          cubit.appendThinking('Thinking...');
          cubit.appendThinking(' more');
        },
        expect: () => [
          const StreamingState(thinking: 'Thinking...', isStreaming: true),
          const StreamingState(thinking: 'Thinking... more', isStreaming: true),
        ],
      );

      test('sets isStreaming so reasoning-only output is rendered', () {
        cubit.appendThinking('thought');

        expect(cubit.state.thinking, 'thought');
        expect(cubit.state.isStreaming, true);
      });

      test('appends empty string without error', () {
        cubit.appendThinking('');

        expect(cubit.state.thinking, isEmpty);
      });
    });

    group('mixed appendText and appendThinking', () {
      test('tracks text and thinking independently', () {
        cubit.appendText('response ');
        cubit.appendThinking('thought ');
        cubit.appendText('continues');
        cubit.appendThinking('deeper');

        expect(cubit.state.text, 'response continues');
        expect(cubit.state.thinking, 'thought deeper');
        expect(cubit.state.isStreaming, true);
      });
    });

    group('reset', () {
      blocTest<StreamingStateCubit, StreamingState>(
        'clears all state back to initial',
        build: () => StreamingStateCubit(coalesceInterval: Duration.zero),
        act: (cubit) {
          cubit.appendText('text');
          cubit.appendThinking('thought');
          cubit.reset();
        },
        expect: () => [
          const StreamingState(text: 'text', isStreaming: true),
          const StreamingState(
            text: 'text',
            thinking: 'thought',
            isStreaming: true,
          ),
          const StreamingState(),
        ],
      );

      test('reset on already-empty state emits default state', () {
        cubit.reset();

        expect(cubit.state, const StreamingState());
      });

      test('can append after reset', () {
        cubit.appendText('first');
        cubit.reset();
        cubit.appendText('second');

        expect(cubit.state.text, 'second');
        expect(cubit.state.isStreaming, true);
      });
    });

    group('delta coalescing', () {
      test(
        'emits the first delta immediately and batches following deltas',
        () async {
          final coalesced = StreamingStateCubit(
            coalesceInterval: const Duration(milliseconds: 10),
          );
          addTearDown(coalesced.close);
          final emitted = <StreamingState>[];
          final subscription = coalesced.stream.listen(emitted.add);
          addTearDown(subscription.cancel);

          coalesced.appendText('A');
          coalesced.appendText('B');
          coalesced.appendText('C');

          expect(coalesced.state.text, 'A');
          await Future<void>.delayed(Duration.zero);
          expect(emitted, [const StreamingState(text: 'A', isStreaming: true)]);

          await Future<void>.delayed(const Duration(milliseconds: 15));

          expect(coalesced.state.text, 'ABC');
          expect(emitted, [
            const StreamingState(text: 'A', isStreaming: true),
            const StreamingState(text: 'ABC', isStreaming: true),
          ]);
        },
      );

      test('batches text and thinking without mixing their content', () async {
        final coalesced = StreamingStateCubit(
          coalesceInterval: const Duration(milliseconds: 10),
        );
        addTearDown(coalesced.close);

        coalesced.appendText('answer ');
        coalesced.appendThinking('reason ');
        coalesced.appendText('done');
        coalesced.appendThinking('done');

        await Future<void>.delayed(const Duration(milliseconds: 15));

        expect(coalesced.state.text, 'answer done');
        expect(coalesced.state.thinking, 'reason done');
      });

      test(
        'reset discards queued deltas and cancels the trailing update',
        () async {
          final coalesced = StreamingStateCubit(
            coalesceInterval: const Duration(milliseconds: 10),
          );
          addTearDown(coalesced.close);
          final emitted = <StreamingState>[];
          final subscription = coalesced.stream.listen(emitted.add);
          addTearDown(subscription.cancel);

          coalesced.appendText('visible');
          coalesced.appendText('queued');
          coalesced.reset();

          await Future<void>.delayed(const Duration(milliseconds: 15));

          expect(coalesced.state, const StreamingState());
          expect(emitted.last, const StreamingState());
          expect(
            emitted,
            isNot(
              contains(
                const StreamingState(text: 'visiblequeued', isStreaming: true),
              ),
            ),
          );
        },
      );

      test(
        'slows the flush cadence once the accumulated text is large',
        () async {
          // Every flush re-parses the whole text through Markdown; a long
          // message must not keep flushing at the short-message cadence.
          final coalesced = StreamingStateCubit(
            coalesceInterval: const Duration(milliseconds: 20),
          );
          addTearDown(coalesced.close);

          coalesced.appendText(
            'x' * (StreamingStateCubit.largeTextThreshold + 1),
          );
          // Let the first (immediate) cycle's trailing timer finish.
          await Future<void>.delayed(const Duration(milliseconds: 150));

          coalesced.appendText('head');
          coalesced.appendText('-tail');
          // The immediate emit publishes 'head'; the queued '-tail' now sits
          // behind a widened (6x = 120ms) timer instead of the base 20ms.
          expect(coalesced.state.text.endsWith('head'), isTrue);

          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(
            coalesced.state.text.endsWith('head'),
            isTrue,
            reason: 'the widened interval must not flush at the base cadence',
          );

          await Future<void>.delayed(const Duration(milliseconds: 160));
          expect(coalesced.state.text.endsWith('head-tail'), isTrue);
        },
      );
    });
  });
}
