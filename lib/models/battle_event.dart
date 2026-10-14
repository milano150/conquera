import 'package:cloud_firestore/cloud_firestore.dart';

/// One resolved attack, written by the attacker's client so every player in
/// the game can replay the invasion on their own map.
class BattleEvent {
  final String id;
  final String attackerId;
  final String? defenderId;
  final String targetId;
  final bool won;
  final List<String> fighterIds;
  final List<String> defenderSupportIds;

  /// When the server recorded it (null while the write is still pending,
  /// which only happens on the attacker's own device).
  final DateTime? at;

  const BattleEvent({
    required this.id,
    required this.attackerId,
    required this.defenderId,
    required this.targetId,
    required this.won,
    required this.fighterIds,
    required this.defenderSupportIds,
    required this.at,
  });

  factory BattleEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    List<String> ids(String key) => [
          for (final v in (d[key] as List? ?? const [])) v as String,
        ];
    return BattleEvent(
      id: doc.id,
      attackerId: d['attackerId'] as String? ?? '',
      defenderId: d['defenderId'] as String?,
      targetId: d['targetId'] as String? ?? '',
      won: d['won'] as bool? ?? false,
      fighterIds: ids('fighterIds'),
      defenderSupportIds: ids('defenderSupportIds'),
      at: (d['at'] as Timestamp?)?.toDate(),
    );
  }
}