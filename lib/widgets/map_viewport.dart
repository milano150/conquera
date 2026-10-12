import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// The map camera's transform (map point -> screen pixel).
///
/// Every write goes through [value], which keeps the camera legal:
///  * horizontally the world is round: once the view has scrolled a full
///    [wrapWidth] the matrix jumps back by exactly one world width. The map
///    is drawn twice side by side, so nobody sees the jump.
///  * vertically the view can't leave [topLimit]..[bottomLimit] (map y).
///
/// Because it's enforced here, the pan gestures, the fling, the zoom, the
/// "fly to the battle" animation and the initial fit all obey the same rules.
class MapCameraController extends TransformationController {
  /// Width of one world in map units. 0 = no wrapping.
  double wrapWidth = 0;

  /// Highest / lowest map y the view may show. Null = unlimited.
  double? topLimit;
  double? bottomLimit;

  /// Height of the viewport in pixels (needed for the bottom limit).
  double viewportHeight = 0;

  @override
  set value(Matrix4 newValue) => super.value = _constrain(newValue);

  Matrix4 _constrain(Matrix4 m) {
    final s = m.getMaxScaleOnAxis();
    if (s <= 0) return m;

    var tx = m.storage[12];
    var ty = m.storage[13];

    if (wrapWidth > 0) {
      // Leave tx in (-period, 0]: the left edge of the screen sits in the
      // first world copy, and the second copy fills whatever is right of it.
      final period = wrapWidth * s;
      tx -= period * (tx / period).ceilToDouble();
    }

    final top = topLimit;
    final bottom = bottomLimit;
    if (top != null && bottom != null && viewportHeight > 0) {
      final hi = -top * s; // view top at the top limit
      final lo = viewportHeight - bottom * s; // view bottom at the bottom limit
      ty = lo > hi ? (lo + hi) / 2 : ty.clamp(lo, hi).toDouble();
    }

    return Matrix4.identity()
      ..translate(tx, ty)
      ..scale(s);
  }
}

/// Pan / pinch-zoom / wheel-zoom viewport for the map, driven by a
/// [MapCameraController]. Replaces InteractiveViewer so the camera can wrap
/// around the world and slow down smoothly after a fling.
///
/// [child] is laid out at [contentSize] and moved by the controller's matrix.
class MapViewport extends StatefulWidget {
  final MapCameraController controller;
  final Size contentSize;
  final double minScale;
  final double maxScale;
  final Widget child;

  /// Called when the player puts a finger down to pan/zoom (e.g. to stop a
  /// camera animation that is still running).
  final VoidCallback? onInteractionStart;

  const MapViewport({
    super.key,
    required this.controller,
    required this.contentSize,
    required this.minScale,
    required this.maxScale,
    required this.child,
    this.onInteractionStart,
  });

  @override
  State<MapViewport> createState() => _MapViewportState();
}

class _MapViewportState extends State<MapViewport>
    with SingleTickerProviderStateMixin {
  /// Fling friction: the share of speed left after one second. Lower = stops
  /// sooner. 0.02 glides for about three quarters of a second.
  static const double _drag = 0.02;

  /// A fling slower than this (px/s) doesn't glide at all.
  static const double _minFlingSpeed = 60;

  late final AnimationController _glide = AnimationController(vsync: this)
    ..addListener(_onGlideTick);

  Offset _lastFocal = Offset.zero;
  double _lastGestureScale = 1;

  FrictionSimulation? _simX;
  FrictionSimulation? _simY;
  double _glideSeconds = 0;
  Offset _glideApplied = Offset.zero;

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  void _setMatrix(double scale, Offset translation) {
    widget.controller.value = Matrix4.identity()
      ..translate(translation.dx, translation.dy)
      ..scale(scale);
  }

  /// Zooms by [ratio] keeping the screen point [focal] fixed, and moves the
  /// view so [focal] ends up at [newFocal] (the pan part of a pinch).
  void _zoomAndMove(double ratio, Offset focal, Offset newFocal) {
    final m = widget.controller.value;
    final s = m.getMaxScaleOnAxis();
    final newScale =
        (s * ratio).clamp(widget.minScale, widget.maxScale).toDouble();
    final t = Offset(m.storage[12], m.storage[13]);
    final mapPoint = (focal - t) / s;
    _setMatrix(newScale, newFocal - mapPoint * newScale);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _glide.stop();
    widget.onInteractionStart?.call();
    _lastFocal = d.localFocalPoint;
    _lastGestureScale = 1;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final total = d.scale <= 0 ? 1.0 : d.scale;
    final ratio = total / _lastGestureScale;
    _zoomAndMove(ratio, _lastFocal, d.localFocalPoint);
    _lastFocal = d.localFocalPoint;
    _lastGestureScale = total;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // Another finger is still down: it's still a gesture.
    if (d.pointerCount > 0) return;

    final v = d.velocity.pixelsPerSecond;
    final speed = v.distance;
    if (speed < _minFlingSpeed) return;

    // Run until the speed has dropped to ~10 px/s.
    final seconds = (math.log(10 / speed) / math.log(_drag)).clamp(0.05, 3.0);
    _simX = FrictionSimulation(_drag, 0, v.dx);
    _simY = FrictionSimulation(_drag, 0, v.dy);
    _glideSeconds = seconds.toDouble();
    _glideApplied = Offset.zero;
    _glide.duration = Duration(milliseconds: (_glideSeconds * 1000).round());
    _glide.forward(from: 0);
  }

  void _onGlideTick() {
    final simX = _simX;
    final simY = _simY;
    if (simX == null || simY == null) return;

    final t = _glide.value * _glideSeconds;
    final travelled = Offset(simX.x(t), simY.x(t));
    final delta = travelled - _glideApplied;
    _glideApplied = travelled;

    // Relative to wherever the camera is now, so the wrap jump and the
    // vertical limit can't make the glide drift or wind up.
    final m = widget.controller.value;
    _setMatrix(
      m.getMaxScaleOnAxis(),
      Offset(m.storage[12] + delta.dx, m.storage[13] + delta.dy),
    );
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _glide.stop();
    final ratio = math.exp(-event.scrollDelta.dy / 200);
    _zoomAndMove(ratio, event.localPosition, event.localPosition);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: widget.contentSize.width,
            maxHeight: widget.contentSize.height,
            child: AnimatedBuilder(
              animation: widget.controller,
              child: widget.child,
              builder: (context, child) => Transform(
                transform: widget.controller.value,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}