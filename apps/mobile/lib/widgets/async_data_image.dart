import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../utils/data_image_decode.dart';

class AsyncDataImage extends StatefulWidget {
  const AsyncDataImage({
    super.key,
    required this.dataUrl,
    this.decoder = decodeDataImageUrl,
    this.fit,
    this.width,
    this.height,
    this.cacheWidth,
    this.gaplessPlayback = false,
    this.loading,
    this.failure,
  });

  final String dataUrl;
  final DataImageDecoder decoder;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final bool gaplessPlayback;
  final Widget? loading;
  final Widget? failure;

  @override
  State<AsyncDataImage> createState() => _AsyncDataImageState();
}

class _AsyncDataImageState extends State<AsyncDataImage> {
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.decoder(widget.dataUrl);
  }

  @override
  void didUpdateWidget(covariant AsyncDataImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataUrl != widget.dataUrl ||
        oldWidget.decoder != widget.decoder) {
      _bytes = widget.decoder(widget.dataUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done && bytes != null) {
          return Image.memory(
            bytes,
            fit: widget.fit,
            width: widget.width,
            height: widget.height,
            cacheWidth: widget.cacheWidth,
            gaplessPlayback: widget.gaplessPlayback,
            errorBuilder: (_, _, _) =>
                widget.failure ?? const SizedBox.shrink(),
          );
        }
        if (snapshot.connectionState == ConnectionState.done ||
            snapshot.hasError) {
          return widget.failure ?? const SizedBox.shrink();
        }
        return widget.loading ?? const SizedBox.shrink();
      },
    );
  }
}
