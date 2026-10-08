import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../models/province.dart';
import '../services/svg_map_parser.dart';

/// Owns the parsed map data and the current selection.
///
/// Deliberately small (plain [ChangeNotifier]) so gameplay state - owners,
/// armies, neighbors, turns - can be layered on later.
class MapController extends ChangeNotifier {
  List<Province> _provinces = const [];
  Map<String, Province> _provinceLookup = const {};
  Size _mapSize = Size.zero;
  String? _selectedProvinceId;
  bool _isLoaded = false;
  Object? _loadError;

  List<Province> get provinces => _provinces;
  Size get mapSize => _mapSize;
  bool get isLoaded => _isLoaded;
  Object? get loadError => _loadError;
  String? get selectedProvinceId => _selectedProvinceId;

  Province? provinceById(String id) => _provinceLookup[id];

  Province? get selectedProvince =>
      _selectedProvinceId == null ? null : _provinceLookup[_selectedProvinceId];

  /// Parses the SVG at [assetPath] and populates [provinces].
  Future<void> loadMap(String assetPath) async {
    try {
      final result = await SvgMapParser.parseAsset(assetPath);
      _provinces = result.provinces;
      _provinceLookup = {for (final p in _provinces) p.id: p};
      _mapSize = result.size;
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
  void selectAt(Offset scenePoint) {
    Province? hit;

    for (final province in _provinces) {
      // Cheap bounding-box rejection before the precise path check.
      if (!province.bounds.contains(scenePoint)) continue;
      if (province.path.contains(scenePoint)) {
        hit = province;
        break;
      }
    }

    if (hit?.id == _selectedProvinceId) return; // nothing changed
    _selectedProvinceId = hit?.id;
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedProvinceId == null) return;
    _selectedProvinceId = null;
    notifyListeners();
  }
}
