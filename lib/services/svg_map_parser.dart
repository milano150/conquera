import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_drawing/path_drawing.dart';
import 'package:xml/xml.dart';

import '../models/province.dart';
import 'map_parse_result.dart';

/// Parses a Simplemaps-style world/region SVG into a list of [Province]s.
///
/// Design notes:
/// * Some regions are drawn as several disjoint `<path>` elements (a
///   mainland plus a few islands). Those share the same `id` (or, when
///   `id` is absent, the same `class`), so we group by that key and merge
///   every sub-path into a single [Path] — the region behaves as one
///   clickable unit no matter how many shapes make it up.
/// * Parsing happens once, at load time. Everything downstream (painting,
///   hit-testing) works off the pre-built [Province] list, so runtime cost
///   stays flat no matter how large the map gets.
class SvgMapParser {
  const SvgMapParser._();

  /// This source SVG draws 52 countries (islands/exclaves split across
  /// multiple disjoint `<path>`s — see class doc) with **no `id` attribute
  /// at all**, only `class="<Country Name>"`. Without this table, those
  /// paths would group under the literal class string (e.g. "Russian
  /// Federation", "United States", "China") instead of an ISO alpha-2
  /// code — which silently breaks anything keyed by ISO code downstream,
  /// e.g. [MapController]'s neighbor map, since those countries would
  /// never match any neighbor entry (in either direction) and end up
  /// permanently unreachable by the dice-move mechanic.
  static const Map<String, String> _classOnlyCountryToIsoCode = {
    'American Samoa': 'AS',
    'Angola': 'AO',
    'Antigua and Barbuda': 'AG',
    'Argentina': 'AR',
    'Australia': 'AU',
    'Azerbaijan': 'AZ',
    'Bahamas': 'BS',
    'Canada': 'CA',
    'Canary Islands (Spain)': 'ES',
    'Cape Verde': 'CV',
    'Cayman Islands': 'KY',
    'Chile': 'CL',
    'China': 'CN',
    'Comoros': 'KM',
    'Cyprus': 'CY',
    'Denmark': 'DK',
    'Faeroe Islands': 'FO',
    'Falkland Islands': 'FK',
    'Federated States of Micronesia': 'FM',
    'Fiji': 'FJ',
    'France': 'FR',
    'French Polynesia': 'PF',
    'Greece': 'GR',
    'Guadeloupe': 'GP',
    'Indonesia': 'ID',
    'Italy': 'IT',
    'Japan': 'JP',
    'Malaysia': 'MY',
    'Malta': 'MT',
    'Mauritius': 'MU',
    'New Caledonia': 'NC',
    'New Zealand': 'NZ',
    'Northern Mariana Islands': 'MP',
    'Norway': 'NO',
    'Oman': 'OM',
    'Papua New Guinea': 'PG',
    'Philippines': 'PH',
    'Puerto Rico': 'PR',
    'Russian Federation': 'RU',
    'Saint Kitts and Nevis': 'KN',
    'Samoa': 'WS',
    'Seychelles': 'SC',
    'Solomon Islands': 'SB',
    'São Tomé and Principe': 'ST',
    'Tonga': 'TO',
    'Trinidad and Tobago': 'TT',
    'Turkey': 'TR',
    'Turks and Caicos Islands': 'TC',
    'United Kingdom': 'GB',
    'United States': 'US',
    'United States Virgin Islands': 'VI',
    'Vanuatu': 'VU',
  };

  /// Loads [assetPath] from the asset bundle and parses it.
  static Future<MapParseResult> parseAsset(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return parseString(raw);
  }

  /// Parses raw SVG markup into a [MapParseResult].
  static MapParseResult parseString(String svgSource) {
    final document = XmlDocument.parse(svgSource);
    final svgRoot = document.findAllElements('svg').first;

    final size = _resolveCanvasSize(svgRoot);
    final offset = _resolveViewBoxOffset(svgRoot);

    final builders = <String, _ProvinceBuilder>{};
    var unnamedCounter = 0;

    for (final pathElement in svgRoot.findAllElements('path')) {
      final d = pathElement.getAttribute('d');
      if (d == null || d.isEmpty) continue;

      final id = pathElement.getAttribute('id');
      final cssClass = pathElement.getAttribute('class');
      final nameAttr = pathElement.getAttribute('name');

      // Group key: prefer the explicit id. Otherwise fall back to the
      // class (used by multi-part countries in this dataset) — but first
      // check whether that class is one of the known id-less countries,
      // so its key still lands on the ISO code the rest of the app
      // (e.g. MapController's neighbor map) expects, rather than the raw
      // class string. Finally synthesize a key so no shape is dropped.
      final key = id ??
          (cssClass != null ? _classOnlyCountryToIsoCode[cssClass] : null) ??
          cssClass ??
          'region_${unnamedCounter++}';
      final displayName = nameAttr ?? cssClass ?? key;

      Path shape = parseSvgPathData(d);
      shape = _smoothPath(shape);
      if (offset != Offset.zero) {
        shape = shape.shift(offset);
      }

      final builder = builders.putIfAbsent(
        key,
        () => _ProvinceBuilder(id: key, name: displayName),
      );
      builder.addShape(shape);
    }

    final provinces = builders.values.map((b) => b.build()).toList();

    return MapParseResult(provinces: provinces, size: size);
  }

  /// Parses the `viewBox` attribute (or `viewbox` — case-insensitive
  /// variants seen in the wild) into its four numeric components, or
  /// returns `null` when the attribute is missing or unparseable.
  static ({double minX, double minY, double width, double height})? _parseViewBox(
    XmlElement svgRoot,
  ) {
    final viewBox =
        svgRoot.getAttribute('viewBox') ?? svgRoot.getAttribute('viewbox');
    if (viewBox == null) return null;

    final parts = viewBox
        .trim()
        .split(RegExp(r'[\s,]+'))
        .map((s) => double.tryParse(s))
        .toList();
    if (parts.length != 4 || parts.any((v) => v == null)) return null;

    return (
      minX: parts[0]!,
      minY: parts[1]!,
      width: parts[2]!,
      height: parts[3]!,
    );
  }

  static Size _resolveCanvasSize(XmlElement svgRoot) {
    final viewBox = _parseViewBox(svgRoot);
    if (viewBox != null) {
      return Size(viewBox.width, viewBox.height);
    }

    final width = double.tryParse(svgRoot.getAttribute('width') ?? '');
    final height = double.tryParse(svgRoot.getAttribute('height') ?? '');
    if (width != null && height != null) {
      return Size(width, height);
    }

    throw const FormatException(
      'Could not determine map size: SVG has neither a valid viewBox '
      'nor valid width/height attributes.',
    );
  }

  static Offset _resolveViewBoxOffset(XmlElement svgRoot) {
    final viewBox = _parseViewBox(svgRoot);
    if (viewBox == null) return Offset.zero;

    if (viewBox.minX != 0 || viewBox.minY != 0) {
      return Offset(-viewBox.minX, -viewBox.minY);
    }
    return Offset.zero;
  }
}

/// Mutable accumulator used only while parsing; merges every sub-path that
/// belongs to the same region and tracks the running bounding box.
class _ProvinceBuilder {
  final String id;
  final String name;
  final Path _mergedPath = Path();
  Rect? _bounds;

  _ProvinceBuilder({required this.id, required this.name});

  void addShape(Path shape) {
    _mergedPath.addPath(shape, Offset.zero);
    final shapeBounds = shape.getBounds();
    _bounds = _bounds == null ? shapeBounds : _bounds!.expandToInclude(shapeBounds);
  }

  Province build() {
    return Province(
      id: id,
      name: name,
      path: _mergedPath,
      bounds: _bounds ?? Rect.zero,
    );
  }
}

/// Rounds off a polygon's sharp vertices via Chaikin's corner-cutting
/// algorithm, run once at parse time.
///
/// This source dataset draws every country as a plain straight-line
/// polygon (`M`/`l`/`Z` only — no curves), with a fairly small vertex
/// count per shape. That's fine at small/zoomed-out display sizes, but
/// once the map is zoomed in (this app's [InteractiveViewer] allows a lot
/// of zoom) those few straight segments read as visibly jagged, faceted
/// borders instead of smooth coastlines.
///
/// Rather than requiring a higher-detail source map, this resamples each
/// contour at a fixed arc-length step (so long straight edges and sharp
/// corners are both represented by enough points to work with) and then
/// runs a couple of Chaikin passes over the result: each pass replaces
/// every point with two points 25%/75% of the way to its neighbor,
/// which cuts every corner into a short chord. Repeated a couple of
/// times this turns sharp vertices into gentle rounded bends while
/// leaving already-straight runs of points visually unchanged (three
/// near-collinear points cut into a chord that sits on the same line).
Path _smoothPath(Path source, {int iterations = 2, double sampleStep = 3.0}) {
  const maxSamplesPerContour = 500;
  final result = Path();

  for (final metric in source.computeMetrics()) {
    final length = metric.length;
    if (length <= 0) continue;

    final sampleCount =
        (length / sampleStep).round().clamp(8, maxSamplesPerContour);
    final step = length / sampleCount;

    final points = <Offset>[];
    for (var i = 0; i < sampleCount; i++) {
      final tangent = metric.getTangentForOffset(i * step);
      if (tangent != null) points.add(tangent.position);
    }

    if (points.length < 4) {
      // Too small a contour to meaningfully smooth — keep it as-is.
      result.addPath(metric.extractPath(0, length), Offset.zero);
      continue;
    }

    var smoothed = points;
    for (var iter = 0; iter < iterations; iter++) {
      smoothed = _chaikinPass(smoothed, closed: metric.isClosed);
    }

    result.moveTo(smoothed.first.dx, smoothed.first.dy);
    for (final p in smoothed.skip(1)) {
      result.lineTo(p.dx, p.dy);
    }
    if (metric.isClosed) result.close();
  }

  return result;
}

/// A single Chaikin corner-cutting pass over an ordered point list. For a
/// closed contour (a country's outline), the sequence wraps around so the
/// last-to-first edge is cut too; for an open one, the original endpoints
/// are preserved so the path doesn't visibly shrink away from its ends.
List<Offset> _chaikinPass(List<Offset> points, {required bool closed}) {
  final n = points.length;
  final limit = closed ? n : n - 1;
  final out = <Offset>[];

  for (var i = 0; i < limit; i++) {
    final p0 = points[i];
    final p1 = points[(i + 1) % n];
    out.add(Offset(
      p0.dx + (p1.dx - p0.dx) * 0.25,
      p0.dy + (p1.dy - p0.dy) * 0.25,
    ));
    out.add(Offset(
      p0.dx + (p1.dx - p0.dx) * 0.75,
      p0.dy + (p1.dy - p0.dy) * 0.75,
    ));
  }

  if (!closed) {
    out.insert(0, points.first);
    out.add(points.last);
  }

  return out;
}
