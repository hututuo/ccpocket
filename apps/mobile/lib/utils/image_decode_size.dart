import 'package:flutter/widgets.dart';

/// Physical-pixel decode bound for an image whose rendered width cannot
/// exceed [logicalWidth].
///
/// Multi-megapixel sources (Bridge screenshots, diff images) decoded at
/// full resolution cost 20-70x the memory of their on-screen size and
/// thrash the image cache; decoding to the render width is visually
/// lossless. Pass the result as `cacheWidth`. Bound by width only: for
/// cover/contain fits a width bound never forces an upscale, a height
/// bound can. Never bound full-screen zoomable viewers.
int decodeWidthForLogical(BuildContext context, double logicalWidth) =>
    (logicalWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
