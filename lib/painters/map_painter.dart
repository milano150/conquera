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
/// One thing to draw on top of a province: its building icon and/or its
/// power. Plain data, so the painter can tell cheaply whether anything
/// changed.
class MapBadge {
  final Offset anchor;
  final IconData? icon;

  /// 0 means "nothing to show".
  final int power;

  const MapBadge({required this.anchor, this.icon, this.power = 0});

  @override
  bool operator ==(Object other) =>
      other is MapBadge &&
      other.anchor == anchor &&
      other.icon == icon &&
      other.power == power;

  @override
  int get hashCode => Object.hash(anchor, icon, power);
}

/// The badge layer: a building icon in the centre of each province that
/// has one, with its power as a small grey number right under it.
///
/// Icons and numbers have a constant size in map units, so they scale with
/// the map exactly like the countries do. Power numbers only appear once
/// the map is zoomed in to [powerMinScale], so the zoomed-out view stays
/// clean.
///
/// It repaints whenever the pan/zoom [transform] changes, without any
/// widget rebuild, and caches its text so that stays cheap.
class BadgePainter extends CustomPainter {
  final List<MapBadge> badges;
  final TransformationController transform;

  /// Zoom level (the viewer's scale) from which power numbers are shown.
  final double powerMinScale;

  /// Icon height and power-number font size, in map units.
  final double iconSize;
  final double powerSize;

  BadgePainter({
    required this.badges,
    required this.transform,
    required this.powerMinScale,
    required this.iconSize,
    required this.powerSize,
  }) : super(repaint: transform);

  final Map<IconData, TextPainter> _iconCache = {};
  final Map<int, TextPainter> _powerCache = {};

  TextPainter _iconPainter(IconData icon) {
    return _iconCache.putIfAbsent(icon, () {
      return TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: iconSize,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: Colors.black,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  TextPainter _powerPainter(int power) {
    return _powerCache.putIfAbsent(power, () {
      return TextPainter(
        text: TextSpan(
          text: '$power',
          style: ConqueraText.label.copyWith(
            fontSize: powerSize,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = transform.value.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final showPower = scale >= powerMinScale;

    for (final badge in badges) {
      final icon = badge.icon;
      final showNumber = showPower && badge.power > 0;
      if (icon == null && !showNumber) continue;

      canvas.save();
      canvas.translate(badge.anchor.dx, badge.anchor.dy);

      if (icon != null) {
        final painter = _iconPainter(icon);
        painter.paint(
          canvas,
          Offset(-painter.width / 2, -painter.height / 2),
        );
      }

      if (showNumber) {
        final painter = _powerPainter(badge.power);
        // Under the icon, or centred when the province has no building.
        final top = icon != null ? iconSize / 2 : -painter.height / 2;
        painter.paint(canvas, Offset(-painter.width / 2, top));
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant BadgePainter oldDelegate) {
    return !listEquals(oldDelegate.badges, badges) ||
        oldDelegate.powerMinScale != powerMinScale ||
        oldDelegate.iconSize != iconSize ||
        oldDelegate.powerSize != powerSize ||
        !identical(oldDelegate.transform, transform);
  }
}