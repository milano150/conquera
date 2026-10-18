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
  final Color? _fillColor;
  final Color? _strokeColor;
  Color get fillColor => _fillColor ?? ConqueraColors.land;
  Color get strokeColor => _strokeColor ?? ConqueraColors.border;
  final double strokeWidth;

  MapPainter({
    required this.provinces,
    this.ownerFillColors = const <String, Color>{},
    this.hiddenIds = const <String>{},
    Color? fillColor,
    Color? strokeColor,
    this.strokeWidth = 0.5,
    this.wrapWidth = 0,
  })  : _fillColor = fillColor,
        _strokeColor = strokeColor;

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
      if (ownerColor != null && ConqueraColors.neon) {
        // Neon look: soft glow, translucent vivid fill, bright edge.
        final neon = _neon(ownerColor);
        canvas.drawPath(
          province.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = strokeWidth * 5
            ..color = neon.withAlpha(120)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
        );
        canvas.drawPath(
          province.path,
          Paint()
            ..style = PaintingStyle.fill
            ..color = neon.withAlpha(150),
        );
        canvas.drawPath(
          province.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..isAntiAlias = true
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = strokeWidth * 1.6
            ..color = neon,
        );
        continue;
      }
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

  static final Map<int, Color> _neonCache = {};

  /// Pushes a player's color to a vivid, bright version for dark mode.
  static Color _neon(Color c) {
    return _neonCache.putIfAbsent(c.value, () {
      final h = HSLColor.fromColor(c.withAlpha(255));
      return h
          .withSaturation(h.saturation < 0.9 ? 0.9 : h.saturation)
          .withLightness(h.lightness.clamp(0.52, 0.62).toDouble())
          .toColor();
    });
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
    canvas.drawPath(selected, line(ConqueraColors.onInk, _corePx));
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
///  * on a loss, the same sweep goes halfway across the target, then pulls
///    back twice as fast (the base layer hides the target meanwhile).
///
/// [fx] runs 0..1 for the sweep (a loss uses the same value for the advance
/// and the retreat). [pulse] drives the outline.
/// Line widths are divided by the zoom so they stay the same on screen.
class BattlePainter extends CustomPainter {
  final BattleView view;
  final Animation<double> pulse;
  final Animation<double> fx;
  final TransformationController transform;

  static const double _casingPx = 3.0;
  static const double _corePx = 1.6;

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

    final t = fx.value;

    if (view.outcome == BattleOutcome.won && t > 0) {
      _paintSweep(canvas, Curves.easeInOutSine.transform(t.clamp(0.0, 1.0)));
    } else if (view.outcome == BattleOutcome.lost) {
      _paintTarget(canvas);
      final reach = _lossReach(t);
      if (reach > 0) _paintSweep(canvas, reach);
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
      view.targetPath,
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

  /// How far a failed attack's sweep has reached (0..1 of the full sweep):
  /// it advances to the halfway mark during the first two thirds of [t],
  /// then falls back to nothing in the last third, twice as fast.
  double _lossReach(double t) {
    const split = 2 / 3;
    if (t <= split) {
      return 0.5 * Curves.easeInOutSine.transform(t / split);
    }
    final back = ((t - split) / (1 - split)).clamp(0.0, 1.0);
    return 0.5 * (1 - Curves.easeInOutSine.transform(back));
  }

  /// The target as the base layer would draw it (the base layer hides it
  /// while a failed attack plays).
  void _paintTarget(Canvas canvas) {
    final path = view.targetPath;
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
  void _paintSweep(Canvas canvas, double fraction) {
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

    final radius = maxRadius * fraction.clamp(0.0, 1.0);
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

  /// 1 = fully visible; lower values fade the whole badge out.
  final double opacity;

  const MapBadge({
    required this.anchor,
    this.icon,
    this.power = 0,
    this.extent = double.infinity,
    this.color,
    this.opacity = 1,
  });

  @override
  bool operator ==(Object other) =>
      other is MapBadge &&
      other.anchor == anchor &&
      other.icon == icon &&
      other.power == power &&
      other.extent == extent &&
      other.color == color &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(anchor, icon, power, extent, color, opacity);
}

/// The badge layer: a building icon in the centre of each province that
/// has one, with its power as a small number right under it.
///
/// Badges are sized to their province, but never below a readable size:
///  * the icon is [iconSize] at most, and never more than [_iconShare] of
///    the province's [MapBadge.extent];
///  * a tiny country (the Maldives, Palau...) would get an unreadable icon
///    from that rule, so it is drawn at least [_tinyIconPx] pixels tall on
///    screen, even if that is bigger than the country itself;
///  * the power number follows the same rules with [powerSize] and
///    [_tinyPowerPx], and only shows once the map is zoomed in to
///    [powerMinScale].
///
/// Everything is drawn in a dark shade of the owner's color, so it reads as
/// part of the map instead of as black stickers.
///
/// It repaints whenever the pan/zoom [transform] changes, without any
/// widget rebuild, and caches its text so that stays cheap.
class BadgePainter extends CustomPainter {
  final List<MapBadge> badges;
  final TransformationController transform;

  /// Zoom level (the viewer's scale) at which power numbers are fully
  /// visible. They start to fade in a little before that, see
  /// [_powerFadeStart].
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

  /// Power numbers begin to fade in at this share of [powerMinScale] and are
  /// fully visible at [powerMinScale].
  static const double _powerFadeStart = 0.8;

  /// Fade steps. The number's color is cached per step, so keep it small.
  static const int _powerFadeSteps = 12;

  /// Smallest icon / number height, in screen pixels. Tiny countries are
  /// drawn at this size, larger than the country itself.
  static const double _tinyIconPx = 14;
  static const double _tinyPowerPx = 12;

  /// How dark the owner's color gets for icons, and how opaque they are.
  static const double _inkMix = 0.62;
  static const int _inkAlpha = 225;

  final Map<String, TextPainter> _iconCache = {};
  final Map<String, TextPainter> _powerCache = {};

  static Color _tint(Color? owner) {
    if (owner == null) return ConqueraColors.ink.withAlpha(_inkAlpha);
    return Color.lerp(
      owner.withAlpha(255),
      ConqueraColors.neon ? ConqueraColors.onInk : ConqueraColors.ink,
      _inkMix,
    )!
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

  /// 0 (hidden) to 1 (fully visible), eased, in [_powerFadeSteps] steps.
  double _powerOpacity(double scale) {
    final from = powerMinScale * _powerFadeStart;
    if (scale <= from) return 0;
    if (scale >= powerMinScale) return 1;
    final t = (scale - from) / (powerMinScale - from);
    final eased = t * t * (3 - 2 * t);
    return (eased * _powerFadeSteps).round() / _powerFadeSteps;
  }

  void _paintOnce(Canvas canvas, Size size) {
    final scale = transform.value.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final powerOpacity = _powerOpacity(scale);
    final showPower = powerOpacity > 0;

    for (final badge in badges) {
      final color = _tint(badge.color);

      // Sized to the province, capped at the normal size.
      final icon = badge.icon;
      final iconMapSize =
          min(iconSize, max(badge.extent * _iconShare, _tinyIconPx / scale));
      final iconFits = icon != null;

      final powerMapSize =
          min(powerSize, max(badge.extent * _powerShare, _tinyPowerPx / scale));
      final showNumber = showPower && badge.power > 0;

      canvas.save();
      canvas.translate(badge.anchor.dx, badge.anchor.dy);
      final faded = badge.opacity < 1;
      if (faded) {
        canvas.saveLayer(
          null,
          Paint()..color = Color.fromRGBO(255, 255, 255, badge.opacity),
        );
      }

      if (icon != null) {
        final painter = _iconPainter(icon, iconMapSize, color);
        painter.paint(
          canvas,
          Offset(-painter.width / 2, -painter.height / 2),
        );
      }

      if (showNumber) {
        final numberColor = color.withAlpha((_inkAlpha * powerOpacity).round());
        final painter = _powerPainter(badge.power, powerMapSize, numberColor);
        // Under the icon, or centred when there's no icon to sit under.
        final top = iconFits ? iconMapSize / 2 : -painter.height / 2;
        painter.paint(canvas, Offset(-painter.width / 2, top));
      }

      if (faded) canvas.restore();
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

/// Darkens everything outside the radars' ranges. Nothing is drawn at
/// [progress] 0; at 1 the whole map is dimmed except a sharp-edged circle for
/// each entry of [circles] (centre, radius). The circles are cut out of the
/// dim layer for every copy of the world, so they wrap around the map edge.
class RadarPainter extends CustomPainter {
  final List<(Offset, double)> circles;

  /// 0..1, already eased.
  final double progress;
  final double wrapWidth;

  static const int _dimAlpha = 140;

  RadarPainter({
    required this.circles,
    required this.progress,
    this.wrapWidth = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (circles.isEmpty || progress <= 0) return;

    // The circles open up while the map dims.
    final grow = 1 + (1 - progress) * 0.6;
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withAlpha((_dimAlpha * progress).round()),
    );
    final offsets = wrapWidth > 0 ? [0.0, wrapWidth, wrapWidth * 2] : [0.0];
    final hole = Paint()
      ..blendMode = BlendMode.dstOut
      ..isAntiAlias = true
      ..color = Colors.black;
    for (final (c, radius) in circles) {
      if (radius <= 0) continue;
      for (final dx in offsets) {
        canvas.drawCircle(Offset(c.dx + dx, c.dy), radius * grow, hole);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant RadarPainter old) =>
      !listEquals(old.circles, circles) ||
      old.progress != progress ||
      old.wrapWidth != wrapWidth;
}