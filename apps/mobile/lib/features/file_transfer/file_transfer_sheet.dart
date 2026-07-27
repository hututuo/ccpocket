import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../artifact_preview/artifact_quick_look_service.dart';
import '../artifact_preview/artifact_transfer_service.dart';
import '../file_browser/file_mutation_authorization.dart';
import 'file_transfer_storage.dart';
import 'file_transfer_service.dart';
import 'received_file_actions.dart';

class FileTransferSettingsTile extends StatelessWidget {
  const FileTransferSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final copy = _TransferCopy.of(context);
    return Card(
      key: const ValueKey('file_transfer_settings_card'),
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: ListTile(
        key: const ValueKey('file_transfer_settings_tile'),
        leading: const Icon(Icons.swap_vert_circle_outlined),
        title: Text(copy.title),
        subtitle: Text(copy.subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showFileTransferSheet(context),
      ),
    );
  }
}

Future<void> showFileTransferSheet(BuildContext context) {
  final service = context.read<FileTransferService>();
  unawaited(_refreshReceivedInbox(service));
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ChangeNotifierProvider<FileTransferService>.value(
      value: service,
      child: const FileTransferSheet(),
    ),
  );
}

Future<void> _refreshReceivedInbox(FileTransferService service) async {
  try {
    await service.refreshReceivedFiles();
    await service.markReceivedFilesSeen();
  } catch (_) {
    // The live transfer controls remain usable if the local inbox is busy.
  }
}

class FileTransferSheet extends StatelessWidget {
  const FileTransferSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<FileTransferService>();
    final copy = _TransferCopy.of(context);
    final active = service.activeTransfer ?? service.pausedTransfer;
    return FractionallySizedBox(
      heightFactor: 0.86,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    copy.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                _StatusCard(service: service, copy: copy),
                const SizedBox(height: 12),
                if (active != null) ...[
                  _ActiveTransferCard(
                    record: active,
                    service: service,
                    copy: copy,
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  key: const ValueKey('file_transfer_upload_button'),
                  onPressed: service.uploadAvailable && active == null
                      ? () => _upload(context, service, copy)
                      : null,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(copy.uploadToMac),
                ),
                if (!service.autoResume && service.queuedTransferCount > 0) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => service.startQueuedTransfers(),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(copy.startQueued(service.queuedTransferCount)),
                  ),
                ],
                const SizedBox(height: 20),
                if (service.receivedFiles.isNotEmpty) ...[
                  Text(
                    copy.received,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  ...service.receivedFiles.map(
                    (file) => _ReceivedFileTile(
                      file: file,
                      copy: copy,
                      canSave: service.receivedFileExportSupported,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                Text(
                  copy.recent,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (service.recentResults.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      copy.noRecent,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  ...service.recentResults.map(
                    (record) => _RecentTransferTile(record: record, copy: copy),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _upload(
    BuildContext context,
    FileTransferService service,
    _TransferCopy copy,
  ) async {
    try {
      await service.uploadToMac(
        authorizeMutation: (operation) =>
            requestFileMutationAuthorization(context, operation),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${copy.failed}: $error')));
    }
  }
}

class _ReceivedFileTile extends StatelessWidget {
  const _ReceivedFileTile({
    required this.file,
    required this.copy,
    required this.canSave,
  });

  final ReceivedFileTransfer file;
  final _TransferCopy copy;
  final bool canSave;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('received_file_${file.path}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
        child: Row(
          children: [
            Icon(
              Icons.download_done_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: () => _preview(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _bytes(file.sizeBytes),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('preview_received_file_${file.path}'),
              tooltip: copy.preview,
              onPressed: () => _preview(context),
              icon: const Icon(Icons.visibility_outlined),
            ),
            IconButton(
              key: ValueKey('share_received_file_${file.path}'),
              tooltip: copy.share,
              onPressed: () => _share(context),
              icon: const Icon(Icons.ios_share_outlined),
            ),
            if (canSave)
              IconButton(
                key: ValueKey('save_received_file_${file.path}'),
                tooltip: copy.saveElsewhere,
                onPressed: () => _save(context),
                icon: const Icon(Icons.save_alt_outlined),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _preview(BuildContext context) async {
    // This file already lives in the app's Downloads directory, so it does not
    // need the smaller automatic artifact-fetch budget. Native Quick Look owns
    // format support; HTML remains outside its WebKit preview sandbox.
    if (!shouldTryQuickLookForLocalFile(
      file.filename,
      '',
      file.sizeBytes,
      maxSizeBytes: maxArtifactTransferBytes,
    )) {
      await _share(context);
      return;
    }
    try {
      await const MethodChannelArtifactQuickLookGateway().previewFile(
        path: file.path,
        title: file.filename,
      );
    } catch (error) {
      if (context.mounted) _showActionError(context, copy, error);
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      final box = context.findRenderObject() as RenderBox?;
      final origin = box == null || !box.hasSize
          ? null
          : box.localToGlobal(Offset.zero) & box.size;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          title: file.filename,
          sharePositionOrigin: origin,
        ),
      );
    } catch (error) {
      if (context.mounted) _showActionError(context, copy, error);
    }
  }

  Future<void> _save(BuildContext context) async {
    try {
      final saved = await const MethodChannelReceivedFileExportGateway()
          .exportFile(path: file.path);
      if (saved && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(copy.savedElsewhere)));
      }
    } catch (error) {
      if (context.mounted) _showActionError(context, copy, error);
    }
  }
}

void _showActionError(BuildContext context, _TransferCopy copy, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${copy.failed}: $error')));
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.service, required this.copy});
  final FileTransferService service;
  final _TransferCopy copy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final available = service.uploadAvailable;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              available ? Icons.link : Icons.link_off,
              color: available ? colorScheme.primary : colorScheme.error,
            ),
            title: Text(available ? copy.ready : copy.unavailable(service)),
            subtitle: Text(copy.filesLocation),
          ),
          const Divider(height: 1, indent: 16, endIndent: 16),
          SwitchListTile.adaptive(
            key: const ValueKey('file_transfer_auto_resume_switch'),
            value: service.autoResume,
            onChanged: service.platformSupported
                ? (value) => unawaited(service.setAutoResume(value))
                : null,
            title: Text(copy.autoResume),
            subtitle: Text(copy.autoResumeDescription),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                copy.limit,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveTransferCard extends StatelessWidget {
  const _ActiveTransferCard({
    required this.record,
    required this.service,
    required this.copy,
  });
  final FileTransferRecord record;
  final FileTransferService service;
  final _TransferCopy copy;

  @override
  Widget build(BuildContext context) {
    final paused = record.status == FileTransferStatus.paused;
    return Card(
      key: const ValueKey('file_transfer_active_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  record.direction == FileTransferDirection.receive
                      ? Icons.download_outlined
                      : Icons.upload_outlined,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    record.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(_percent(record.progress)),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: record.progress),
            const SizedBox(height: 8),
            Text(
              '${_bytes(record.transferredBytes)} / ${_bytes(record.totalBytes)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: paused
                      ? () => _resume(context)
                      : service.pauseActive,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                  label: Text(paused ? copy.resume : copy.pause),
                ),
                TextButton.icon(
                  onPressed: () => _confirmCancel(context),
                  icon: const Icon(Icons.close),
                  label: Text(copy.cancel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(copy.cancelTitle),
        content: Text(copy.cancelBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(copy.cancel),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await service.cancelTransfer(record.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${copy.failed}: $error')));
    }
  }

  Future<void> _resume(BuildContext context) async {
    try {
      await service.continuePaused(
        authorizeMutation: (operation) =>
            requestFileMutationAuthorization(context, operation),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${copy.failed}: $error')));
    }
  }
}

class _RecentTransferTile extends StatelessWidget {
  const _RecentTransferTile({required this.record, required this.copy});
  final FileTransferRecord record;
  final _TransferCopy copy;

  @override
  Widget build(BuildContext context) {
    final succeeded = record.status == FileTransferStatus.succeeded;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        succeeded ? Icons.check_circle_outline : Icons.info_outline,
        color: succeeded
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.error,
      ),
      title: Text(record.savedFilename ?? record.filename),
      subtitle: Text(
        succeeded
            ? '${copy.completed} · ${_bytes(record.totalBytes)}'
            : '${record.errorCode ?? copy.failed} · ${_bytes(record.transferredBytes)}',
      ),
    );
  }
}

String _percent(double value) => '${(value * 100).clamp(0, 100).round()}%';

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KiB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

class _TransferCopy {
  final bool zh;
  const _TransferCopy(this.zh);
  factory _TransferCopy.of(BuildContext context) =>
      _TransferCopy(Localizations.localeOf(context).languageCode == 'zh');

  String get title => zh ? '文件互传' : 'File Transfer';
  String get subtitle =>
      zh ? 'Mac 与 iPhone 双向续传' : 'Resumable Mac ↔ iPhone transfer';
  String get uploadToMac => zh ? '上传到 Mac' : 'Upload to Mac';
  String get ready => zh ? '已连接，可双向传输' : 'Connected and ready';
  String unavailable(FileTransferService service) {
    if (!service.platformSupported) {
      return zh
          ? '当前 iPhone 系统或 APP 构建不支持文件互传'
          : 'This iPhone system or app build does not support File Transfer';
    }
    if (!service.isConnected) {
      return zh ? '连接 Mac 后才可文件互传' : 'Connect to the Mac for File Transfer';
    }
    return zh ? '当前 Bridge 不支持文件互传 V2' : 'File Transfer V2 unavailable';
  }

  String get filesLocation => zh
      ? '接收文件：文件 App > CC Pocket > Downloads'
      : 'Received files: Files > CC Pocket > Downloads';
  String get autoResume => zh ? '自动继续未完成传输' : 'Automatically resume';
  String get autoResumeDescription => zh
      ? '仅在同一台已连接的 Mac 上续传，不进入聊天离线队列'
      : 'Only on the same live Mac; never enters the chat offline queue';
  String get limit =>
      zh ? '单文件上限 15 GiB · 分块流式传输' : '15 GiB per file · streamed in chunks';
  String get recent => zh ? '最近传输' : 'Recent transfers';
  String get received => zh ? '电脑发来的文件' : 'Files received from Mac';
  String get preview => zh ? '预览' : 'Preview';
  String get share => zh ? '分享' : 'Share';
  String get saveElsewhere => zh ? '另存到文件' : 'Save to Files';
  String get savedElsewhere => zh ? '文件已另存' : 'File saved';
  String get noRecent => zh ? '还没有传输记录' : 'No recent transfers';
  String get pause => zh ? '暂停' : 'Pause';
  String get resume => zh ? '继续' : 'Resume';
  String get cancel => zh ? '取消传输' : 'Cancel';
  String get cancelTitle => zh ? '取消这个传输？' : 'Cancel this transfer?';
  String get cancelBody => zh
      ? '未完成的分块和恢复凭据会被清理；已经完成的目标文件不会删除。'
      : 'Partial data and resume credentials will be removed. Completed files are never deleted.';
  String get completed => zh ? '已完成' : 'Completed';
  String get failed => zh ? '失败' : 'Failed';
  String startQueued(int count) =>
      zh ? '开始 $count 个待接收文件' : 'Start $count queued transfer(s)';
}
