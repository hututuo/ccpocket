import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'streaming_state.dart';

/// Manages the high-frequency streaming state for a chat session.
///
/// Kept separate from [ChatSessionCubit] to avoid rebuilding the
/// entire message list on every streaming delta.
class StreamingStateCubit extends Cubit<StreamingState> {
  StreamingStateCubit({
    this.coalesceInterval = const Duration(milliseconds: 32),
  }) : super(const StreamingState());

  /// Maximum cadence for publishing subsequent stream deltas.
  ///
  /// The first delta is emitted immediately. Deltas received before the next
  /// interval are combined into one state update, avoiding quadratic string
  /// copying and full Markdown rebuilds for every network chunk.
  final Duration coalesceInterval;

  Timer? _flushTimer;
  StringBuffer _pendingText = StringBuffer();
  StringBuffer _pendingThinking = StringBuffer();

  void appendText(String text) {
    _append(text: text);
  }

  void appendThinking(String text) {
    _append(thinking: text);
  }

  void _append({String text = '', String thinking = ''}) {
    if (coalesceInterval <= Duration.zero) {
      _emitAppended(text: text, thinking: thinking);
      return;
    }

    if (_flushTimer == null) {
      _emitAppended(text: text, thinking: thinking);
      _scheduleFlush();
      return;
    }

    _pendingText.write(text);
    _pendingThinking.write(thinking);
  }

  void _scheduleFlush() {
    _flushTimer = Timer(coalesceInterval, _flushPending);
  }

  void _flushPending() {
    _flushTimer = null;
    if (isClosed) return;

    final text = _pendingText.toString();
    final thinking = _pendingThinking.toString();
    _pendingText = StringBuffer();
    _pendingThinking = StringBuffer();

    if (text.isEmpty && thinking.isEmpty) return;
    _emitAppended(text: text, thinking: thinking);

    // Keep a steady upper bound while deltas are arriving continuously. The
    // next idle tick observes no pending data and lets the timer stop.
    if (!isClosed) _scheduleFlush();
  }

  void _emitAppended({required String text, required String thinking}) {
    emit(
      state.copyWith(
        text: state.text + text,
        thinking: state.thinking + thinking,
        isStreaming: true,
      ),
    );
  }

  void reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingText = StringBuffer();
    _pendingThinking = StringBuffer();
    emit(const StreamingState());
  }

  @override
  Future<void> close() {
    _flushTimer?.cancel();
    _flushTimer = null;
    return super.close();
  }
}
