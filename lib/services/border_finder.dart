import 'dart:math';
import 'dart:ui';

import '../models/province.dart';

/// Works out which provinces border each other, straight from the map
/// geometry (the SVG has no neighbor data).
///
/// Every outline is sampled every few map units and dropped into a spatial
/// grid. Two provinces are neighbors when a sample of one lies within
/// [_reachFraction] of the map's longest side from a sample of the other.
/// That is just wide enough to bridge the hairline gaps between countries
/// in the SVG, and (as a side effect) lets very narrow straits count as a
/// border. Raise [_reachFraction] if real neighbors are missed; lower it if
/// countries across a strait border each other when they shouldn't.
///
/// Runs once, right after the map is parsed.
class BorderFinder {
  const BorderFinder._();

  static const double _reachFraction = 0.001;

  /// provinceId -> ids of every province that borders it (both directions).
  static Map<String, Set<String>> find(List<Province> provinces, Size mapSize) {
    final longest = max(mapSize.width, mapSize.height);
    if (longest <= 0 || provinces.isEmpty) return const {};

    final reach = longest * _reachFraction;
    final step = reach * 0.75;
    final cell = reach;

    final xs = <double>[];
    final ys = <double>[];
    final owner = <int>[];
    final grid = <int, List<int>>{};

    int keyOf(int cx, int cy) => cx * 100003 + cy;

    void addSample(double x, double y, int provinceIndex) {
      final i = xs.length;
      xs.add(x);
      ys.add(y);
      owner.add(provinceIndex);
      grid
          .putIfAbsent(keyOf((x / cell).floor(), (y / cell).floor()), () => [])
          .add(i);
    }

    for (var p = 0; p < provinces.length; p++) {
      for (final metric in provinces[p].path.computeMetrics()) {
        final length = metric.length;
        var d = 0.0;
        while (d < length) {
          final t = metric.getTangentForOffset(d);
          if (t != null) addSample(t.position.dx, t.position.dy, p);
          d += step;
        }
        final end = metric.getTangentForOffset(length);
        if (end != null) addSample(end.position.dx, end.position.dy, p);
      }
    }

    final neighbors = <String, Set<String>>{};
    final linked = <int>{};
    final reachSq = reach * reach;
    final count = provinces.length;

    for (var i = 0; i < xs.length; i++) {
      final a = owner[i];
      final cx = (xs[i] / cell).floor();
      final cy = (ys[i] / cell).floor();

      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final bucket = grid[keyOf(cx + dx, cy + dy)];
          if (bucket == null) continue;
          for (final j in bucket) {
            final b = owner[j];
            if (b == a) continue;
            final ox = xs[j] - xs[i];
            final oy = ys[j] - ys[i];
            if (ox * ox + oy * oy > reachSq) continue;

            final lo = min(a, b);
            final hi = max(a, b);
            if (!linked.add(lo * count + hi)) continue;

            final idA = provinces[a].id;
            final idB = provinces[b].id;
            (neighbors[idA] ??= <String>{}).add(idB);
            (neighbors[idB] ??= <String>{}).add(idA);
          }
        }
      }
    }
    return neighbors;
  }
}