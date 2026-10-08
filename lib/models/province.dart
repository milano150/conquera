import 'dart:ui';

/// Immutable representation of a single clickable region on the map
/// (a country in the source SVG today, a province once the game data
/// is subdivided further).
///
/// [path] is the merged geometry of every SVG `<path>` element that
/// belongs to this entity (some countries are drawn as several disjoint
/// shapes — mainland + islands — but should behave as one clickable
/// unit). [bounds] is precomputed once so hit-testing can cheaply reject
/// far-away taps before running the more expensive [Path.contains] check.
class Province {
  final String id;
  final String name;
  final Path path;
  final Rect bounds;

  const Province({
    required this.id,
    required this.name,
    required this.path,
    required this.bounds,
  });

  @override
  String toString() => 'Province(id: $id, name: $name)';
}
