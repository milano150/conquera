import 'dart:ui';

import '../models/province.dart';

/// Everything the map widget needs after the SVG has been parsed:
/// the list of clickable [provinces] plus the intrinsic canvas [size]
/// (taken from the SVG's viewBox/width/height) so the painter and the
/// pan/zoom viewport agree on the same coordinate space.
class MapParseResult {
  final List<Province> provinces;
  final Size size;

  const MapParseResult({required this.provinces, required this.size});
}
