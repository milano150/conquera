import 'package:cloud_firestore/cloud_firestore.dart';

/// A province's document under games/{gameId}/provinces/{provinceId}.
/// The document id is the SVG province id ("US", "FR", ...). A province
/// with no document is neutral.
class ProvinceState {
  final String id;
  final String? ownerId;

  /// Idle-style snapshot, like gold: the current value will be derived
  /// from this plus [troopsUpdatedAt] once troops regenerate.
  final double troops;
  final DateTime? troopsUpdatedAt;

  final String buildingType;
  final int buildingLevel;

  const ProvinceState({
    required this.id,
    required this.ownerId,
    required this.troops,
    required this.troopsUpdatedAt,
    required this.buildingType,
    required this.buildingLevel,
  });

  factory ProvinceState.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final building = data['building'];
    final updated = data['troopsUpdatedAt'];
    return ProvinceState(
      id: doc.id,
      ownerId: data['ownerId'] as String?,
      troops: (data['troops'] as num?)?.toDouble() ?? 0,
      troopsUpdatedAt: updated is Timestamp ? updated.toDate() : null,
      buildingType:
          building is Map ? (building['type'] as String? ?? 'none') : 'none',
      buildingLevel:
          building is Map ? (building['level'] as num?)?.toInt() ?? 0 : 0,
    );
  }

  /// Text for the info panel.
  String get buildingLabel {
    if (buildingType == 'none' || buildingType.isEmpty) return 'None';
    final name = buildingType[0].toUpperCase() + buildingType.substring(1);
    return buildingLevel > 0 ? '$name (level $buildingLevel)' : name;
  }
}