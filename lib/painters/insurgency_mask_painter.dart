import 'package:flutter/material.dart';

import '../models/province.dart';

/// Blacks out the whole map except the [visible] provinces (the insurgent's
/// hideout and its neighbours). Drawn on both world copies. [progress]
/// (0..1) fades the black in or out.
class InsurgencyMaskPainter extends CustomPainter {
  final List<Province> visible;

  /// The hideout itself: drawn fully. Every other visible province is only
  /// half see-through ([neighborDim] of black over it).
  final String? hostId;
  final double wrapWidth;
  final Animation<double> progress;

  static const double neighborDim = 0.5;

  /// White laid over the hideout to make it brighter.
  static const double hostBrightness = 0.28;

  InsurgencyMaskPainter({
    required this.visible,
    required this.hostId,
    required this.wrapWidth,
    required this.progress,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0) return;
    final copies = wrapWidth > 0 ? 2 : 1;
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    for (var i = 0; i < copies; i++) {
      for (final p in visible) {
        path.addPath(p.path, Offset(i * wrapWidth, 0));
      }
    }
    final a = t.clamp(0.0, 1.0).toDouble();
    canvas.drawPath(
      path,
      Paint()
        ..isAntiAlias = true
        ..color = Color.fromRGBO(0, 0, 0, a),
    );

    // The bordering countries stay visible but faded.
    final dim = Paint()
      ..isAntiAlias = true
      ..color = Color.fromRGBO(0, 0, 0, a * neighborDim);
    for (var i = 0; i < copies; i++) {
      for (final p in visible) {
        if (p.id == hostId) continue;
        canvas.drawPath(p.path.shift(Offset(i * wrapWidth, 0)), dim);
      }
    }

    // The hideout itself is lit up, so it stands out from its neighbours.
    final glow = Paint()
      ..isAntiAlias = true
      ..color = Color.fromRGBO(255, 255, 255, a * hostBrightness);
    for (var i = 0; i < copies; i++) {
      for (final p in visible) {
        if (p.id != hostId) continue;
        canvas.drawPath(p.path.shift(Offset(i * wrapWidth, 0)), glow);
      }
    }
  }

  @override
  bool shouldRepaint(InsurgencyMaskPainter old) =>
      old.visible != visible ||
      old.hostId != hostId ||
      old.wrapWidth != wrapWidth;
}

/// Diagonal zebra stripes in the insurgent's color over the hideout, to show
/// the territory is also theirs. Fades in and out with [progress].
class InsurgencyStripePainter extends CustomPainter {
  final Province? host;
  final Color color;
  final double wrapWidth;
  final Animation<double> progress;

  InsurgencyStripePainter({
    required this.host,
    required this.color,
    required this.wrapWidth,
    required this.progress,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    final h = host;
    final t = progress.value;
    if (h == null || t <= 0) return;

    // Stripe size is in map units, so it scales with the zoom like the
    // territory does.
    final unit = (wrapWidth > 0 ? wrapWidth : size.width / 2) * 0.006;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = unit
      ..color = color.withAlpha((170 * t.clamp(0.0, 1.0)).round());

    final copies = wrapWidth > 0 ? 2 : 1;
    final b = h.bounds;
    for (var i = 0; i < copies; i++) {
      canvas.save();
      canvas.translate(i * wrapWidth, 0);
      canvas.clipPath(h.path);
      for (var x = b.left - b.height; x < b.right; x += unit * 2) {
        canvas.drawLine(
          Offset(x, b.bottom),
          Offset(x + b.height, b.top),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(InsurgencyStripePainter old) =>
      old.host != host || old.color != color || old.wrapWidth != wrapWidth;
}
