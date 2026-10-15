import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/province.dart';
import '../config/sea_links.dart';
import '../services/border_finder.dart';
import '../services/svg_map_parser.dart';

/// Owns the parsed map data and the current selection.
///
/// Deliberately small (plain [ChangeNotifier]) so gameplay state - owners,
/// armies, neighbors, turns - can be layered on later.
class MapController extends ChangeNotifier {
  List<Province> _provinces = const [];
  Map<String, Province> _provinceLookup = const {};
  Map<String, Set<String>> _neighbors = const {};
  Size _mapSize = Size.zero;
  String? _selectedProvinceId;
  final Map<String, _TapTarget> _tapTargets = {};
  bool _isLoaded = false;
  Object? _loadError;

  List<Province> get provinces => _provinces;
  Size get mapSize => _mapSize;
  bool get isLoaded => _isLoaded;
  Object? get loadError => _loadError;
  String? get selectedProvinceId => _selectedProvinceId;

  Province? provinceById(String id) => _provinceLookup[id];

  /// Ids of the provinces that share a border with [id].
  Set<String> neighborsOf(String id) => _neighbors[id] ?? const <String>{};

  Province? get selectedProvince =>
      _selectedProvinceId == null ? null : _provinceLookup[_selectedProvinceId];

  /// Parses the SVG at [assetPath] and populates [provinces].
  Future<void> loadMap(String assetPath) async {
    try {
      final result = await SvgMapParser.parseAsset(assetPath);
      _provinces = result.provinces;
      _provinceLookup = {for (final p in _provinces) p.id: p};
      _buildTapTargets();
      _mapSize = result.size;
      final neighbors = <String, Set<String>>{
        for (final e in BorderFinder.find(_provinces, _mapSize).entries)
          e.key: {...e.value},
      };
      for (final link in seaLinks) {
        final a = link.$1;
        final b = link.$2;
        if (!_provinceLookup.containsKey(a) ||
            !_provinceLookup.containsKey(b)) {
          debugPrint('Sea link skipped (not on the map): $a - $b');
          continue;
        }
        (neighbors[a] ??= <String>{}).add(b);
        (neighbors[b] ??= <String>{}).add(a);
      }
      _neighbors = neighbors;
      _isLoaded = true;
      _loadError = null;
    } catch (error, stackTrace) {
      _loadError = error;
      debugPrint('MapController: failed to load "$assetPath": $error');
      debugPrintStack(stackTrace: stackTrace);
    }
    notifyListeners();
  }

  /// Hit-tests [scenePoint] (already in map/canvas coordinates) and updates
  /// the selection. Tapping the ocean clears it.
  ///
  /// [scale] is the current camera zoom (screen pixels per map unit). It
  /// lets tiny territories be hit from a few pixels away, see
  /// [_nearestTinyProvince].
  void selectAt(Offset scenePoint, {double scale = 1}) {
    Province? hit;

    for (final province in _provinces) {
      // Cheap bounding-box rejection before the precise path check.
      if (!province.bounds.contains(scenePoint)) continue;
      if (province.path.contains(scenePoint)) {
        hit = province;
        break;
      }
    }

    // Missed every shape exactly: give tiny territories a bigger touch area.
    hit ??= _nearestTinyProvince(scenePoint, scale);

    if (hit?.id == _selectedProvinceId) return; // nothing changed
    _selectedProvinceId = hit?.id;
    notifyListeners();
  }

  /// A territory whose biggest piece is smaller than this many map units
  /// is a candidate for the bigger touch area.
  static const double _tinyMaxSide = 40;

  /// How far (screen pixels) from a tiny territory's outline a tap still
  /// selects it. 22 px each way makes a 44 px touch target.
  static const double _touchRadiusPx = 22;

  /// The help only applies while the territory is drawn smaller than this
  /// on screen, so it fades out as the player zooms in.
  static const double _helpBelowPx = 44;

  /// Stores outline points for every tiny territory, once, after loading.
  void _buildTapTargets() {
    _tapTargets.clear();
    for (final p in _provinces) {
      final metrics = p.path.computeMetrics().toList();
      var biggest = 0.0;
      for (final m in metrics) {
        final b = m.extractPath(0, m.length).getBounds();
        biggest = math.max(biggest, math.max(b.width, b.height));
      }
      if (biggest >= _tinyMaxSide) continue;

      final samples = <Offset>[];
      for (final m in metrics) {
        samples.add(m.extractPath(0, m.length).getBounds().center);
        for (var d = 0.0; d < m.length; d += 2) {
          final t = m.getTangentForOffset(d);
          if (t != null) samples.add(t.position);
        }
      }
      _tapTargets[p.id] = _TapTarget(biggest, samples);
    }
  }

  /// The tiny territory closest to [point], if one lies within the touch
  /// radius. Distances wrap around the map edge, like the world does.
  Province? _nearestTinyProvince(Offset point, double scale) {
    if (scale <= 0) return null;
    final wrap = _mapSize.width;
    var bestDistance = _touchRadiusPx / scale;
    String? bestId;

    for (final entry in _tapTargets.entries) {
      final target = entry.value;
      if (target.maxSide * scale >= _helpBelowPx) continue;
      for (final s in target.samples) {
        var dx = (s.dx - point.dx).abs();
        if (wrap > 0 && dx > wrap / 2) dx = wrap - dx;
        final dy = s.dy - point.dy;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < bestDistance) {
          bestDistance = d;
          bestId = entry.key;
        }
      }
    }
    return bestId == null ? null : _provinceLookup[bestId];
  }

  void clearSelection() {
    if (_selectedProvinceId == null) return;
    _selectedProvinceId = null;
    notifyListeners();
  }
}

/// Outline points of one tiny territory, and the size of its biggest piece.
class _TapTarget {
  final double maxSide;
  final List<Offset> samples;

  const _TapTarget(this.maxSide, this.samples);
}