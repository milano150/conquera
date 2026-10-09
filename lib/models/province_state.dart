import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/game_rules.dart';

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

  bool get hasBuilding => buildingType != 'none' && buildingType.isNotEmpty;

  /// Text for the info panel and the province window. The level is stored
  /// but not shown for now.
  String get buildingLabel {
    if (!hasBuilding) return 'None';
    return GameRules.buildingById(buildingType)?.name ??
        _prettify(buildingType);
  }

  static String _prettify(String raw) {
    final spaced = raw.replaceAll('_', ' ');
    return spaced[0].toUpperCase() + spaced.substring(1);
  }
}