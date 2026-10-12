import 'dart:math';

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

  /// Provinces left out of this layer (the battle layer draws them itself,
  /// e.g. while one shakes).
  final Set<String> hiddenIds;
  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;

  MapPainter({
    required this.provinces,
    this.ownerFillColors = const <String, Color>{},
    this.hiddenIds = const <String>{},
    this.fillColor = ConqueraColors.land,
    this.strokeColor = ConqueraColors.border,
    this.strokeWidth = 0.5,
    this.wrapWidth = 0,
  });

  /// Width of one world in map units. When set, the layer is drawn twice
  /// side by side so the map can wrap around horizontally.
  final double wrapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final copies = wrapWidth > 0 ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      canvas.save();
      canvas.translate(i * wrapWidth, 0);
      _paintOnce(canvas, size);
      canvas.restore();
    }
  }

  void _paintOnce(Canvas canvas, Size size) {
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
      if (hiddenIds.contains(province.id)) continue;
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
        !setEquals(oldDelegate.hiddenIds, hiddenIds) ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.wrapWidth != wrapWidth;
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

  SelectionPainter({
    required this.path,
    required this.scale,
    this.wrapWidth = 0,
  });

  /// Width of one world in map units. When set, the layer is drawn twice
  /// side by side so the map can wrap around horizontally.
  final double wrapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final copies = wrapWidth > 0 ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      canvas.save();
      canvas.translate(i * wrapWidth, 0);
      _paintOnce(canvas, size);
      canvas.restore();
    }
  }

  void _paintOnce(Canvas canvas, Size size) {
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
    return !identical(oldDelegate.path, path) ||
        oldDelegate.scale != scale ||
        oldDelegate.wrapWidth != wrapWidth;
  }
}
/// 0..1 opacity as a 0..255 alpha.
int _alpha(double opacity) => min(255, max(0, (opacity * 255).round()));

/// How a battle ended, as far as the battle layer is concerned.
enum BattleOutcome { pending, won, lost }

/// Everything the [BattlePainter] needs to know about the running battle.
class BattleView {
  /// The attacker's provinces that take part, outlined in [attackerColor].
  final List<Path> attackerPaths;
  final Color attackerColor;

  /// The province under attack, outlined in [defenderColor], along with the
  /// defender's barracks that help defend it.
  final Path targetPath;
  final List<Path> defenderSupportPaths;
  final Color defenderColor;

  final BattleOutcome outcome;

  /// Unit vector pointing from the attackers toward the target: the way the
  /// sweep travels when the attack is won.
  final Offset sweepDirection;

  /// Opacity of the owner fill (0-255), so the sweep matches the map.
  final int fillAlpha;

  /// Whether the involved provinces get their pulsing border. On for a war,
  /// off when someone just annexes unclaimed land.
  final bool showOutlines;

  const BattleView({
    required this.attackerPaths,
    required this.attackerColor,
    required this.targetPath,
    this.defenderSupportPaths = const [],
    required this.defenderColor,
    required this.outcome,
    required this.sweepDirection,
    required this.fillAlpha,
    this.showOutlines = true,
  });
}

/// The battle layer, drawn between the base map and the badges:
///  * the borders of every involved province (the attacker's in its color,
///    the defender's in its color), gently pulsing;
///  * on a win, a circle that grows over the target from the side the attack
///    comes from ([BattleView.sweepDirection]), turning it from the defender's
///    color to the attacker's;
///  * on a loss, a shake of the target (the base layer hides it meanwhile).
///
/// [fx] runs 0..1 for the sweep or the shake. [pulse] drives the outline.
/// Line widths are divided by the zoom so they stay the same on screen.
class BattlePainter extends CustomPainter {
  final BattleView view;
  final Animation<double> pulse;
  final Animation<double> fx;
  final TransformationController transform;

  static const double _casingPx = 4.6;
  static const double _corePx = 2.6;
  static const double _shakePx = 5;

  BattlePainter({
    required this.view,
    required this.pulse,
    required this.fx,
    required this.transform,
    this.wrapWidth = 0,
  }) : super(repaint: Listenable.merge([pulse, fx, transform]));

  /// Width of one world in map units. When set, the layer is drawn twice
  /// side by side so the map can wrap around horizontally.
  final double wrapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final copies = wrapWidth > 0 ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      canvas.save();
      canvas.translate(i * wrapWidth, 0);
      _paintOnce(canvas, size);
      canvas.restore();
    }
  }

  void _paintOnce(Canvas canvas, Size size) {
    final scale = transform.value.getMaxScaleOnAxis();
    if (scale <= 0) return;

    var shift = Offset.zero;
    final t = fx.value;

    if (view.outcome == BattleOutcome.won && t > 0) {
      _paintSweep(canvas, scale, t);
    } else if (view.outcome == BattleOutcome.lost) {
      // Damped wobble: 5 swings, fading out.
      final wobble = sin(t * pi * 10) * (1 - t) * _shakePx / scale;
      shift = Offset(wobble, 0);
      _paintShakenTarget(canvas, shift);
    }

    if (!view.showOutlines) return;

    final alpha = 0.6 + 0.4 * pulse.value;
    for (final path in view.attackerPaths) {
      _outline(canvas, path, view.attackerColor, scale, alpha);
    }
    for (final path in view.defenderSupportPaths) {
      _outline(canvas, path, view.defenderColor, scale, alpha);
    }
    _outline(
      canvas,
      view.targetPath.shift(shift),
      view.defenderColor,
      scale,
      alpha,
    );
  }

  void _outline(Canvas canvas, Path path, Color color, double scale, double a) {
    Paint line(Color c, double px) => Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = c
      ..strokeWidth = px / scale;

    canvas.drawPath(path, line(ConqueraColors.ink.withAlpha(_alpha(a)), _casingPx));
    canvas.drawPath(path, line(color.withAlpha(_alpha(a)), _corePx));
  }

  /// The target as the base layer would draw it, but moved by [shift].
  void _paintShakenTarget(Canvas canvas, Offset shift) {
    final path = view.targetPath.shift(shift);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = ConqueraColors.land,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = view.defenderColor.withAlpha(view.fillAlpha),
    );
  }

  /// Paints the attacker's color over the target as a circle that grows out
  /// of the side the attack comes from, like an expanding arc: its center is
  /// where the attackers meet the target's edge, and it ends up large enough
  /// to cover the whole territory, however big or small that is.
  void _paintSweep(Canvas canvas, double scale, double t) {
    final bounds = view.targetPath.getBounds();
    var d = view.sweepDirection;
    if (d.distance == 0) d = const Offset(1, 0);
    d = d / d.distance;

    // Entry point: the edge of the target's box facing the attackers.
    final halfExtent =
        d.dx.abs() * bounds.width / 2 + d.dy.abs() * bounds.height / 2;
    final entry = bounds.center - d * halfExtent;

    // Radius that reaches the farthest corner of the target.
    var maxRadius = 0.0;
    for (final corner in [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      maxRadius = max(maxRadius, (corner - entry).distance);
    }
    maxRadius *= 1.03;
    if (maxRadius <= 0) return;

    final progress = t.clamp(0.0, 1.0).toDouble();
    final eased = Curves.easeInOutSine.transform(progress);
    final radius = maxRadius * eased;
    if (radius <= 0) return;

    // Solid color all the way to the rim: blank the old owner's color, then
    // lay the new one on top, both inside the growing circle.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: entry, radius: radius)));
    canvas.drawPath(
      view.targetPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = ConqueraColors.land,
    );
    canvas.drawPath(
      view.targetPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = view.attackerColor.withAlpha(view.fillAlpha),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BattlePainter oldDelegate) {
    return !identical(oldDelegate.view, view) ||
        !identical(oldDelegate.pulse, pulse) ||
        !identical(oldDelegate.fx, fx) ||
        !identical(oldDelegate.transform, transform) ||
        oldDelegate.wrapWidth != wrapWidth;
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

  /// How big the province is, in map units (about the width of its bounding
  /// box). Small countries get small badges, or only a dot when zoomed out.
  final double extent;

  /// The owner's color; the icon and number are drawn in a dark shade of it.
  final Color? color;

  const MapBadge({
    required this.anchor,
    this.icon,
    this.power = 0,
    this.extent = double.infinity,
    this.color,
  });

  @override
  bool operator ==(Object other) =>
      other is MapBadge &&
      other.anchor == anchor &&
      other.icon == icon &&
      other.power == power &&
      other.extent == extent &&
      other.color == color;

  @override
  int get hashCode => Object.hash(anchor, icon, power, extent, color);
}

/// The badge layer: a building icon in the centre of each province that
/// has one, with its power as a small number right under it.
///
/// Badges are sized to their province, so a tiny country never gets an icon
/// bigger than itself:
///  * the icon is [iconSize] at most, and never more than [_iconShare] of
///    the province's [MapBadge.extent];
///  * while that icon would be smaller than [_minIconPx] on screen, a small
///    dot marks the building instead (and nothing at all if even the
///    province itself is only a few pixels wide);
///  * the power number follows the same rule with [powerSize], and only
///    shows once the map is zoomed in to [powerMinScale].
///
/// Everything is drawn in a dark shade of the owner's color, so it reads as
/// part of the map instead of as black stickers.
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
    this.wrapWidth = 0,
  }) : super(repaint: transform);

  /// Largest icon / number, as a share of the province's extent.
  static const double _iconShare = 0.45;
  static const double _powerShare = 0.3;

  /// Smallest icon / number worth drawing, in screen pixels.
  static const double _minIconPx = 9;
  static const double _minPowerPx = 8;

  /// A province narrower than this on screen gets no marker at all.
  static const double _minDotProvincePx = 5;

  /// How dark the owner's color gets for icons, and how opaque they are.
  static const double _inkMix = 0.62;
  static const int _inkAlpha = 225;

  final Map<String, TextPainter> _iconCache = {};
  final Map<String, TextPainter> _powerCache = {};

  static Color _tint(Color? owner) {
    if (owner == null) return ConqueraColors.ink.withAlpha(_inkAlpha);
    return Color.lerp(owner.withAlpha(255), ConqueraColors.ink, _inkMix)!
        .withAlpha(_inkAlpha);
  }

  TextPainter _iconPainter(IconData icon, double size, Color color) {
    final key = '${icon.codePoint}|${size.toStringAsFixed(2)}|${color.hashCode}';
    return _iconCache.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: size,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  TextPainter _powerPainter(int power, double size, Color color) {
    final key = '$power|${size.toStringAsFixed(2)}|${color.hashCode}';
    return _powerCache.putIfAbsent(key, () {
      return TextPainter(
        text: TextSpan(
          text: '$power',
          style: ConqueraText.label.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  /// Width of one world in map units. When set, the layer is drawn twice
  /// side by side so the map can wrap around horizontally.
  final double wrapWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final copies = wrapWidth > 0 ? 2 : 1;
    for (var i = 0; i < copies; i++) {
      canvas.save();
      canvas.translate(i * wrapWidth, 0);
      _paintOnce(canvas, size);
      canvas.restore();
    }
  }

  void _paintOnce(Canvas canvas, Size size) {
    final scale = transform.value.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final showPower = scale >= powerMinScale;

    for (final badge in badges) {
      final provincePx = badge.extent * scale;
      final color = _tint(badge.color);

      // Sized to the province, capped at the normal size.
      final icon = badge.icon;
      final iconMapSize = min(iconSize, badge.extent * _iconShare);
      final iconFits = icon != null && iconMapSize * scale >= _minIconPx;

      final powerMapSize = min(powerSize, badge.extent * _powerShare);
      final showNumber = showPower &&
          badge.power > 0 &&
          powerMapSize * scale >= _minPowerPx;

      canvas.save();
      canvas.translate(badge.anchor.dx, badge.anchor.dy);

      if (icon != null && !iconFits) {
        // Too small for the icon: a dot, unless the province itself is a
        // speck on screen.
        if (provincePx >= _minDotProvincePx) {
          final radius = (provincePx * 0.1).clamp(1.5, 3.5) / scale;
          canvas.drawCircle(
            Offset.zero,
            radius,
            Paint()..color = color,
          );
          canvas.drawCircle(
            Offset.zero,
            radius,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.8 / scale
              ..color = Colors.white.withAlpha(200),
          );
        }
      } else if (icon != null) {
        final painter = _iconPainter(icon, iconMapSize, color);
        painter.paint(
          canvas,
          Offset(-painter.width / 2, -painter.height / 2),
        );
      }

      if (showNumber) {
        final painter = _powerPainter(badge.power, powerMapSize, color);
        // Under the icon, or centred when there's no icon to sit under.
        final top = iconFits ? iconMapSize / 2 : -painter.height / 2;
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
        oldDelegate.wrapWidth != wrapWidth ||
        !identical(oldDelegate.transform, transform);
  }
}