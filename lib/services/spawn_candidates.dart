import '../models/province.dart';

/// Countries a player can start (or respawn) in: anything bigger than
/// Djibouti, so nobody spawns on a small island nation. If Djibouti isn't on
/// the map, falls back to the median size.
List<String> spawnCandidatesFor(List<Province> provinces) {
  final usable = provinces.where((p) => p.id != 'AQ').toList();
  if (usable.isEmpty) return const [];
  double area(Province p) => p.bounds.width * p.bounds.height;

  double? minArea;
  for (final p in usable) {
    if (p.id == 'DJ') minArea = area(p);
  }
  if (minArea == null) {
    final areas = usable.map(area).toList()..sort();
    minArea = areas[areas.length ~/ 2];
  }
  final threshold = minArea;
  return [
    for (final p in usable)
      if (area(p) > threshold) p.id,
  ];
}