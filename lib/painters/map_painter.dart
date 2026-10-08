import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/province.dart';
import '../theme/conquera_theme.dart';

/// The base layer: every province, drawn once.
///
/// This layer knows nothing about selection, so tapping a country never
/// repaints it, and neither does panning or zooming. It only repaints
/// when the province list or an owner color changes.
class MapPainter extends CustomPainter {
  final List<Province> provinces;

  /// provinceId -> color drawn over the land fill. Missing = neutral.
  final Map<String, Color> ownerFillColors;
  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;

  MapPainter({
    required this.provinces,
    this.ownerFillColors = const <String, Color>{},
    this.fillColor = ConqueraColors.land,
    this.strokeColor = ConqueraColors.border,
    this.strokeWidth = 0.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = fillColor;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = strokeColor
      ..strokeWidth = strokeWidth;

    for (final province in provinces) {
      canvas.drawPath(province.path, fillPaint);

      final ownerColor = ownerFillColors[province.id];
      if (ownerColor != null) {
        canvas.drawPath(
          province.path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = ownerColor,
        );
      }

      canvas.drawPath(province.path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.provinces.length != provinces.length ||
        !mapEquals(oldDelegate.ownerFillColors, ownerFillColors) ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// The selection layer: outlines one province on top of the base layer.
///
/// The outline is a dark casing with a white core, so it reads on land,
/// on sea, and later on any player color. Its width is divided by the
/// current zoom [scale], which keeps it the same thickness on screen at
/// every zoom level instead of ballooning when zoomed in.
class SelectionPainter extends CustomPainter {
  final Path? path;
  final double scale;

  static const double _casingPx = 3.4;
  static const double _corePx = 1.4;

  SelectionPainter({required this.path, required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final selected = path;
    if (selected == null || scale <= 0) return;

    Paint line(Color color, double px) => Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = color
      ..strokeWidth = px / scale;

    canvas.drawPath(selected, line(ConqueraColors.ink, _casingPx));
    canvas.drawPath(selected, line(Colors.white, _corePx));
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) {
    return !identical(oldDelegate.path, path) || oldDelegate.scale != scale;
  }
}