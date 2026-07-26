import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/app_localizations.dart';
import 'artifact_quick_look_service.dart';
import 'artifact_transfer_service.dart';

@visibleForTesting
Uri embeddedArtifactPreviewUri(Uri previewUrl) {
  return previewUrl
      .replace(
        queryParameters: <String, String>{
          ...previewUrl.queryParameters,
          'embedded': '1',
        },
      )
      .removeFragment();
}

@visibleForTesting
Uri artifactDownloadUri(Uri previewUrl) {
  final previewPath = previewUrl.path.endsWith('/')
      ? previewUrl.path.substring(0, previewUrl.path.length - 1)
      : previewUrl.path;
  return Uri(
    scheme: previewUrl.scheme,
    userInfo: previewUrl.userInfo,
    host: previewUrl.host,
    port: previewUrl.hasPort ? previewUrl.port : null,
    path: '$previewPath/download',
  );
}

@visibleForTesting
bool isAllowedArtifactPreviewNavigation(Uri previewUrl, Uri candidate) {
  if (candidate.scheme != previewUrl.scheme ||
      candidate.host != previewUrl.host ||
      candidate.port != previewUrl.port) {
    return false;
  }
  final previewPath = previewUrl.path.endsWith('/')
      ? previewUrl.path.substring(0, previewUrl.path.length - 1)
      : previewUrl.path;
  return candidate.path == previewPath ||
      candidate.path == '$previewPath/content' ||
      candidate.path == '$previewPath/download' ||
      candidate.path == '$previewPath/sandbox' ||
      candidate.path.startsWith('/artifacts/assets/');
}

@visibleForTesting
bool artifactPreviewRequiresJavaScript(String filename, String mimeType) {
  return isHtmlArtifact(filename, mimeType) ||
      filename.toLowerCase().endsWith('.docx') ||
      mimeType.toLowerCase().startsWith(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
}

bool supportsEmbeddedArtifactPreview([TargetPlatform? platform]) {
  if (kIsWeb) return false;
  return (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
}

class ArtifactPreviewScreen extends StatefulWidget {
  final Uri previewUrl;
  final String filename;
  final String mimeType;
  final int sizeBytes;
  final String? expiresAt;
  final ArtifactQuickLookPreviewer quickLookPreviewer;
  final Future<void> Function()? onDownloadRequested;
  final String? Function()? downloadUnavailableMessage;

  const ArtifactPreviewScreen({
    super.key,
    required this.previewUrl,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    this.expiresAt,
    this.quickLookPreviewer = const ArtifactQuickLookService(),
    this.onDownloadRequested,
    this.downloadUnavailableMessage,
  });

  @override
  State<ArtifactPreviewScreen> createState() => _ArtifactPreviewScreenState();
}

enum _ArtifactTransferAction { share, download }

class _ArtifactTransferSession {
  final client = http.Client();
  final cancellation = ArtifactTransferCancellation();

  void cancel() => cancellation.cancel();
  void close() => client.close();
}

class _ArtifactPreviewScreenState extends State<ArtifactPreviewScreen> {
  WebViewController? _controller;
  late final Uri _embeddedUrl;
  late final Uri _downloadUrl;
  late final bool _quickLookEligible;
  var _usesQuickLook = false;
  var _pageProgress = 0;
  var _chromeVisible = true;
  var _quickLookBusy = false;
  _ArtifactTransferAction? _transferAction;
  double? _transferProgress;
  String? _mainFrameError;
  _ArtifactTransferSession? _activeTransfer;
  var _handlingBack = false;
  var _webViewCanGoBack = false;

  @override
  void initState() {
    super.initState();
    _embeddedUrl = embeddedArtifactPreviewUri(widget.previewUrl);
    _downloadUrl = artifactDownloadUri(widget.previewUrl);
    _quickLookEligible = shouldTryQuickLookForArtifact(
      widget.filename,
      widget.mimeType,
      widget.sizeBytes,
    );
    _usesQuickLook = _quickLookEligible;
    if (_usesQuickLook) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_previewWithQuickLook());
      });
      return;
    }
    _initializeWebPreview();
  }

  void _initializeWebPreview() {
    if (_controller != null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(
        artifactPreviewRequiresJavaScript(widget.filename, widget.mimeType)
            ? JavaScriptMode.unrestricted
            : JavaScriptMode.disabled,
      )
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _pageProgress = progress);
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _mainFrameError = null;
                _pageProgress = 0;
              });
            }
            unawaited(_refreshWebViewBackState());
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _pageProgress = 100);
            unawaited(_refreshWebViewBackState());
          },
          onWebResourceError: (error) {
            final failedUrl = Uri.tryParse(error.url ?? '');
            final isMainFrame =
                error.isForMainFrame == true ||
                (error.isForMainFrame == null &&
                    failedUrl?.scheme == _embeddedUrl.scheme &&
                    failedUrl?.host == _embeddedUrl.host &&
                    failedUrl?.port == _embeddedUrl.port &&
                    failedUrl?.path == _embeddedUrl.path);
            if (isMainFrame && mounted) {
              setState(() => _mainFrameError = error.description);
            }
          },
          onHttpError: (error) {
            if (error.request?.uri.path == widget.previewUrl.path && mounted) {
              setState(
                () =>
                    _mainFrameError = 'HTTP ${error.response?.statusCode ?? 0}',
              );
            }
          },
          onNavigationRequest: (request) {
            final candidate = Uri.tryParse(request.url);
            if (candidate == null) return NavigationDecision.prevent;
            if (candidate == _downloadUrl) {
              unawaited(_downloadArtifact());
              return NavigationDecision.prevent;
            }
            return isAllowedArtifactPreviewNavigation(
                  widget.previewUrl,
                  candidate,
                )
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(_embeddedUrl);
  }

  @override
  void dispose() {
    _activeTransfer?.cancel();
    super.dispose();
  }

  void _setChromeVisible(bool value) {
    setState(() => _chromeVisible = value);
  }

  Future<void> _refreshWebViewBackState() async {
    final controller = _controller;
    if (controller == null) return;
    final canGoBack = await controller.canGoBack();
    if (!mounted || canGoBack == _webViewCanGoBack) return;
    setState(() => _webViewCanGoBack = canGoBack);
  }

  Future<void> _handleBack() async {
    if (_handlingBack) return;
    _handlingBack = true;
    try {
      final controller = _controller;
      if (controller != null && await controller.canGoBack()) {
        await controller.goBack();
        await _refreshWebViewBackState();
        return;
      }
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) _handlingBack = false;
    }
  }

  Rect? _sharePositionOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<File> _fetchArtifactTo(
    Directory directory,
    _ArtifactTransferSession transfer,
  ) async {
    File? reservedFile;
    var handedToStreamService = false;
    try {
      if (transfer.cancellation.isCancelled) {
        throw const ArtifactTransferException('cancelled');
      }
      reservedFile = await reserveNextAvailableArtifactFile(
        directory,
        widget.filename,
      );
      if (transfer.cancellation.isCancelled) {
        throw const ArtifactTransferException('cancelled');
      }
      handedToStreamService = true;
      await streamArtifactToFile(
        client: transfer.client,
        url: _downloadUrl,
        destination: reservedFile,
        expectedSizeBytes: widget.sizeBytes,
        cancellation: transfer.cancellation,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _transferProgress = total > 0 ? received / total : null;
          });
        },
      );
      return reservedFile;
    } finally {
      if (!handedToStreamService &&
          reservedFile != null &&
          await reservedFile.exists()) {
        try {
          if (await reservedFile.length() == 0) await reservedFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _shareArtifact() async {
    if (_transferAction != null || _quickLookBusy) return;
    final transfer = _ArtifactTransferSession();
    _activeTransfer = transfer;
    setState(() {
      _transferAction = _ArtifactTransferAction.share;
      _transferProgress = null;
    });
    File? temporaryFile;
    try {
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}/artifact-shares',
      );
      if (transfer.cancellation.isCancelled) return;
      temporaryFile = await _fetchArtifactTo(directory, transfer);
      if (!mounted || transfer.cancellation.isCancelled) return;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(temporaryFile.path, mimeType: widget.mimeType)],
          fileNameOverrides: <String>[
            safeArtifactDownloadFilename(widget.filename),
          ],
          title: widget.filename,
          sharePositionOrigin: _sharePositionOrigin(),
        ),
      );
    } catch (_) {
      if (mounted) _showError(AppLocalizations.of(context).artifactOpenFailed);
    } finally {
      if (temporaryFile != null && await temporaryFile.exists()) {
        try {
          await temporaryFile.delete();
        } catch (_) {}
      }
      if (identical(_activeTransfer, transfer)) _activeTransfer = null;
      transfer.close();
      if (mounted) {
        setState(() {
          _transferAction = null;
          _transferProgress = null;
        });
      }
    }
  }

  Future<void> _downloadArtifact() async {
    if (_transferAction != null || _quickLookBusy) return;
    final unavailableMessage = widget.downloadUnavailableMessage?.call();
    if (unavailableMessage != null) {
      _showError(unavailableMessage);
      return;
    }
    final externalDownload = widget.onDownloadRequested;
    if (externalDownload != null) {
      setState(() {
        _transferAction = _ArtifactTransferAction.download;
        _transferProgress = null;
      });
      try {
        await externalDownload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${AppLocalizations.of(context).download}: ${widget.filename}',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          _showError(AppLocalizations.of(context).artifactOpenFailed);
        }
      } finally {
        if (mounted) {
          setState(() {
            _transferAction = null;
            _transferProgress = null;
          });
        }
      }
      return;
    }
    final transfer = _ArtifactTransferSession();
    _activeTransfer = transfer;
    setState(() {
      _transferAction = _ArtifactTransferAction.download;
      _transferProgress = null;
    });
    try {
      final documents = await getApplicationDocumentsDirectory();
      if (transfer.cancellation.isCancelled) return;
      final file = await _fetchArtifactTo(
        Directory('${documents.path}/Downloads'),
        transfer,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLocalizations.of(context).download}: ${file.uri.pathSegments.last}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (_) {
      if (mounted) _showError(AppLocalizations.of(context).artifactOpenFailed);
    } finally {
      if (identical(_activeTransfer, transfer)) _activeTransfer = null;
      transfer.close();
      if (mounted) {
        setState(() {
          _transferAction = null;
          _transferProgress = null;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _previewWithQuickLook() async {
    if (!_usesQuickLook || _quickLookBusy || _transferAction != null) return;
    final transfer = _ArtifactTransferSession();
    _activeTransfer = transfer;
    setState(() {
      _quickLookBusy = true;
      _transferProgress = null;
    });
    try {
      await widget.quickLookPreviewer.previewTemporaryArtifact(
        prepareFile: () async {
          final temporaryDirectory = Directory(
            '${(await getTemporaryDirectory()).path}/artifact-previews',
          );
          if (transfer.cancellation.isCancelled) {
            throw const ArtifactTransferException('cancelled');
          }
          return _fetchArtifactTo(temporaryDirectory, transfer);
        },
        title: widget.filename,
        isCancelled: () => transfer.cancellation.isCancelled || !mounted,
      );
    } on ArtifactQuickLookUnsupportedException {
      if (mounted && !transfer.cancellation.isCancelled) {
        _initializeWebPreview();
        setState(() => _usesQuickLook = false);
      }
    } catch (_) {
      if (mounted && !transfer.cancellation.isCancelled) {
        // Any Quick Look failure falls back to the WebView preview, not just
        // the explicit "unsupported" signal (E.4 §5); the snackbar is a
        // non-blocking notice instead of a dead-end error card.
        _initializeWebPreview();
        setState(() => _usesQuickLook = false);
        _showError(AppLocalizations.of(context).artifactOpenFailed);
      }
    } finally {
      if (identical(_activeTransfer, transfer)) _activeTransfer = null;
      transfer.close();
      if (mounted) {
        setState(() {
          _quickLookBusy = false;
          _transferProgress = null;
        });
      }
    }
  }

  String get _sizeLabel {
    if (widget.sizeBytes < 1024) return '${widget.sizeBytes} B';
    if (widget.sizeBytes < 1024 * 1024) {
      return '${(widget.sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(widget.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _actionButton({
    required _ArtifactTransferAction action,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool filled,
  }) {
    final active = _transferAction == action;
    final child = active
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: _transferProgress,
            ),
          )
        : Icon(icon, size: 19);
    final buttonChild = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[child, const SizedBox(width: 7), Text(label)],
    );
    return filled
        ? FilledButton(
            onPressed: _transferAction == null && !_quickLookBusy
                ? onPressed
                : null,
            child: buttonChild,
          )
        : OutlinedButton(
            onPressed: _transferAction == null && !_quickLookBusy
                ? onPressed
                : null,
            child: buttonChild,
          );
  }

  Widget _buildQuickLookBody(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return Stack(
      children: <Widget>[
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.insert_drive_file_outlined, size: 52),
                const SizedBox(height: 14),
                Text(
                  widget.filename,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                if (_quickLookBusy)
                  SizedBox(
                    width: 180,
                    child: LinearProgressIndicator(value: _transferProgress),
                  )
                else
                  FilledButton.icon(
                    onPressed: _previewWithQuickLook,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text(localizations.codeFontPreview),
                  ),
              ],
            ),
          ),
        ),
        if (!_chromeVisible) _buildChromeRevealButton(context),
      ],
    );
  }

  Widget _buildChromeRevealButton(BuildContext context) {
    return Positioned(
      top: 8,
      right: 8,
      child: SafeArea(
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          elevation: 3,
          borderRadius: BorderRadius.circular(12),
          child: IconButton(
            onPressed: () => _setChromeVisible(true),
            tooltip: AppLocalizations.of(context).showMore,
            icon: const Icon(Icons.expand_more),
          ),
        ),
      ),
    );
  }

  Widget _buildWebPreviewBody(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final controller = _controller!;
    return Stack(
      children: <Widget>[
        WebViewWidget(controller: controller),
        if (_pageProgress < 100)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _pageProgress / 100,
              minHeight: 2,
            ),
          ),
        if (!_chromeVisible) _buildChromeRevealButton(context),
        if (_mainFrameError != null)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.insert_drive_file_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      localizations.artifactOpenFailed,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: _handleBack,
                          icon: const Icon(Icons.arrow_back),
                          label: Text(localizations.back),
                        ),
                        FilledButton.icon(
                          onPressed: () => controller.loadRequest(_embeddedUrl),
                          icon: const Icon(Icons.refresh),
                          label: Text(localizations.retry),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    return AppBar(
      leading: BackButton(onPressed: _handleBack),
      titleSpacing: 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '$_sizeLabel · ${widget.mimeType.split(';').first}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      actions: <Widget>[
        IconButton(
          onPressed: () => _setChromeVisible(false),
          tooltip: localizations.showLess,
          icon: const Icon(Icons.expand_less),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(58),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: _actionButton(
                  action: _ArtifactTransferAction.share,
                  icon: Icons.ios_share,
                  label: localizations.share,
                  onPressed: _shareArtifact,
                  filled: false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  action: _ArtifactTransferAction.download,
                  icon: Icons.download_outlined,
                  label: localizations.download,
                  onPressed: _downloadArtifact,
                  filled: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      // Keep Flutter's native route pop enabled whenever the embedded viewer
      // has no page of its own to return to. In particular, this restores the
      // iOS edge-swipe gesture on the Office share/download fallback shown
      // after Quick Look is dismissed.
      canPop: !_webViewCanGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: _chromeVisible ? _buildAppBar(context) : null,
        body: _usesQuickLook
            ? _buildQuickLookBody(context)
            : _buildWebPreviewBody(context),
      ),
    );
  }
}
