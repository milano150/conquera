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
///
/// [anchor] is a point guaranteed to lie inside the region (on its biggest
/// shape), close to its visual centre. It is where the building icon and
/// power number are drawn.
class Province {
  final String id;
  final String name;
  final Path path;
  final Rect bounds;
  final Offset anchor;

  const Province({
    required this.id,
    required this.name,
    required this.path,
    required this.bounds,
    required this.anchor,
  });

  @override
  String toString() => 'Province(id: $id, name: $name)';
}