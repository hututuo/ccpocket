import 'package:flutter/material.dart';

import '../models/messages.dart';
import '../theme/app_theme.dart';

@immutable
class ChatMessageTimestampData {
  const ChatMessageTimestampData({
    required this.value,
    required this.approximate,
  });

  factory ChatMessageTimestampData.fromEntry(ChatEntry entry) {
    return ChatMessageTimestampData(
      value: entry.timestamp,
      approximate: !entry.timestampIsAuthoritative,
    );
  }

  final DateTime value;
  final bool approximate;

  String get label =>
      '${approximate ? '~' : ''}'
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

class ChatMessageTimestampText extends StatelessWidget {
  const ChatMessageTimestampText({
    super.key,
    required this.timestamp,
    this.color,
  });

  final ChatMessageTimestampData timestamp;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final appColors = Theme.of(context).extension<AppColors>()!;
    return Text(
      timestamp.label,
      key: const ValueKey('chat_message_timestamp'),
      style: TextStyle(
        fontSize: 10,
        height: 1.1,
        color: color ?? appColors.subtleText,
      ),
    );
  }
}
