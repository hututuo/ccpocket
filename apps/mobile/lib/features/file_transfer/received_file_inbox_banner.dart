import 'dart:async';

import 'package:flutter/material.dart';

import 'file_transfer_service.dart';
import 'file_transfer_sheet.dart';

class ReceivedFileInboxBanner extends StatelessWidget {
  const ReceivedFileInboxBanner({
    super.key,
    required this.service,
  });

  final FileTransferService service;

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final count = service.unreadReceivedCount;
    final latest = service.receivedFiles.isEmpty
        ? null
        : service.receivedFiles.first.filename;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        key: const ValueKey('received_file_inbox_banner'),
        color: cs.secondaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: cs.secondary.withValues(alpha: 0.45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Badge(
            label: Text('$count'),
            child: Icon(Icons.download_done_rounded, color: cs.secondary),
          ),
          title: Text(
            zh ? '电脑发来了 $count 个文件' : '$count file(s) received from Mac',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: latest == null
              ? null
              : Text(
                  latest,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: IconButton(
            key: const ValueKey('dismiss_received_file_inbox_banner'),
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: () => unawaited(service.markReceivedFilesSeen()),
            icon: const Icon(Icons.close),
          ),
          onTap: () => showFileTransferSheet(context),
        ),
      ),
    );
  }
}
