import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../l10n/app_localizations.dart';
import '../services/connection_url_parser.dart';
import '../utils/platform_helper.dart';

@RoutePage()
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  MobileScannerController? _controller;
  bool _hasPopped = false;
  final _invalidNoticeGate = QrInvalidNoticeGate();

  bool get _isSupported => !kIsWeb && isMobilePlatform;

  @override
  void initState() {
    super.initState();
    if (_isSupported) {
      _controller = MobileScannerController();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasPopped) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;

      final params = ConnectionUrlParser.parse(value);
      if (params != null) {
        _hasPopped = true;
        context.router.maybePop(params);
        return;
      }
    }

    // The scanner can report the same invalid code on every camera frame.
    // Keep scanning, but never stack duplicate notices while one is visible.
    if (!_invalidNoticeGate.tryAcquire()) return;
    final notice = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).qrScanInvalid),
        duration: const Duration(seconds: 2),
      ),
    );
    unawaited(notice.closed.whenComplete(_invalidNoticeGate.release));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.scanQrCode)),
      body: !_isSupported || controller == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.qrScanUnavailable,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Stack(
              children: [
                MobileScanner(controller: controller, onDetect: _onDetect),
                // Scan frame overlay
                Center(
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: colorScheme.primary.withValues(alpha: 0.7),
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                // Hint text
                Positioned(
                  bottom: 80,
                  left: 0,
                  right: 0,
                  child: Text(
                    l10n.qrScanHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colorScheme.onSurface.withValues(alpha: 0.8),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

@visibleForTesting
class QrInvalidNoticeGate {
  bool _active = false;

  bool tryAcquire() {
    if (_active) return false;
    _active = true;
    return true;
  }

  void release() {
    _active = false;
  }
}
