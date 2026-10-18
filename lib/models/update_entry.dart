import 'package:cloud_firestore/cloud_firestore.dart';

/// One territory in a battle report, with its troops before and after.
class TroopRow {
  final String id;
  final double before;
  final double after;

  /// True for the territory that was attacked.
  final bool isTarget;

  const TroopRow({
    required this.id,
    required this.before,
    required this.after,
    this.isTarget = false,
  });

  factory TroopRow.fromMap(Map<String, dynamic> m) => TroopRow(
        id: m['id'] as String? ?? '',
        before: (m['before'] as num?)?.toDouble() ?? 0,
        after: (m['after'] as num?)?.toDouble() ?? 0,
        isTarget: m['target'] as bool? ?? false,
      );
}

enum UpdateType { attack, build, destroy, missile }

/// One line of a player's "Updates" feed, stored under
/// games/{gameId}/players/{uid}/updates/{id}: an attack they did or faced,
/// a building they built, or one they destroyed.
class UpdateEntry {
  final String id;
  final UpdateType type;

  /// When the server recorded it (null while the write is still pending).
  final DateTime? at;

  // Attacks
  final String attackerId;
  final String? defenderId;
  final String targetId;
  final bool won;
  final double attackerPower;
  final double defenderPower;
  final double defenseMultiplier;

  /// The building on the target before the attack ('none' if there was none).
  final String targetBuilding;
  final List<TroopRow> attackers;
  final List<TroopRow> defenders;

  // Buildings
  final String provinceId;
  final String buildingId;

  /// Missile strikes: power the hit removed ([targetBuilding] is what it
  /// destroyed, [provinceId] the silo that fired).
  final double powerRemoved;

  const UpdateEntry({
    required this.id,
    required this.type,
    required this.at,
    this.attackerId = '',
    this.defenderId,
    this.targetId = '',
    this.won = false,
    this.attackerPower = 0,
    this.defenderPower = 0,
    this.defenseMultiplier = 1,
    this.targetBuilding = 'none',
    this.attackers = const [],
    this.defenders = const [],
    this.provinceId = '',
    this.buildingId = '',
    this.powerRemoved = 0,
  });

  factory UpdateEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    List<TroopRow> rows(String key) => [
          for (final v in (d[key] as List? ?? const []))
            if (v is Map) TroopRow.fromMap(Map<String, dynamic>.from(v)),
        ];
    final type = switch (d['type']) {
      'build' => UpdateType.build,
      'destroy' => UpdateType.destroy,
      'missile' => UpdateType.missile,
      _ => UpdateType.attack,
    };
    return UpdateEntry(
      id: doc.id,
      type: type,
      at: (d['at'] as Timestamp?)?.toDate(),
      attackerId: d['attackerId'] as String? ?? '',
      defenderId: d['defenderId'] as String?,
      targetId: d['targetId'] as String? ?? '',
      won: d['won'] as bool? ?? false,
      attackerPower: (d['attackerPower'] as num?)?.toDouble() ?? 0,
      defenderPower: (d['defenderPower'] as num?)?.toDouble() ?? 0,
      defenseMultiplier: (d['defenseMultiplier'] as num?)?.toDouble() ?? 1,
      targetBuilding: d['targetBuilding'] as String? ?? 'none',
      attackers: rows('attackers'),
      defenders: rows('defenders'),
      provinceId: d['provinceId'] as String? ?? '',
      buildingId: d['buildingId'] as String? ?? '',
      powerRemoved: (d['powerRemoved'] as num?)?.toDouble() ?? 0,
    );
  }
}