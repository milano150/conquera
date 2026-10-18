import 'package:cloud_firestore/cloud_firestore.dart';

/// One missile launch, stored under games/{gameId}/missiles so every player
/// can watch it fly. (Not part of the public Log.)
class MissileEvent {
  final String id;
  final String attackerId;
  final String? defenderId;

  /// The province holding the silo that fired.
  final String fromId;

  /// The province that was hit.
  final String targetId;

  /// The building the missile destroyed ('none' if there was none).
  final String building;

  /// Null while the server timestamp is still pending (the shooter's own
  /// device, right after firing).
  final DateTime? at;

  const MissileEvent({
    required this.id,
    required this.attackerId,
    required this.defenderId,
    required this.fromId,
    required this.targetId,
    required this.building,
    required this.at,
  });

  factory MissileEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    return MissileEvent(
      id: doc.id,
      attackerId: d['attackerId'] as String? ?? '',
      defenderId: d['defenderId'] as String?,
      fromId: d['fromId'] as String? ?? '',
      targetId: d['targetId'] as String? ?? '',
      building: d['building'] as String? ?? 'none',
      at: (d['at'] as Timestamp?)?.toDate(),
    );
  }
}