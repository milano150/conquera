import 'package:cloud_firestore/cloud_firestore.dart';

enum LogType { annex, attack, join, eliminated, respawn }

/// One line of the world-wide Log, read from games/{gameId}/events.
///
/// [actorId] is whoever did the thing (the attacker, the player who annexed,
/// joined or respawned, or, for an elimination, the player who eliminated
/// someone). For an elimination, [victimId] is the player who was removed.
/// Names and colors are stored on the event too, so the Log still reads
/// correctly after a player has left the world.
class LogEntry {
  final String id;
  final LogType type;
  final DateTime? at;

  final String actorId;
  final String? actorName;
  final String? actorColor;

  final String? victimId;
  final String? victimName;
  final String? victimColor;

  /// The territory annexed or attacked.
  final String targetId;
  final bool won;

  const LogEntry({
    required this.id,
    required this.type,
    required this.at,
    required this.actorId,
    this.actorName,
    this.actorColor,
    this.victimId,
    this.victimName,
    this.victimColor,
    this.targetId = '',
    this.won = false,
  });

  factory LogEntry.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final type = switch (d['type']) {
      'annex' => LogType.annex,
      'join' => LogType.join,
      'eliminated' => LogType.eliminated,
      'respawn' => LogType.respawn,
      _ => LogType.attack, // older attack events have no type
    };
    return LogEntry(
      id: doc.id,
      type: type,
      at: (d['at'] as Timestamp?)?.toDate(),
      actorId: (d['actorId'] ?? d['attackerId']) as String? ?? '',
      actorName: d['actorName'] as String?,
      actorColor: d['actorColor'] as String?,
      victimId: d['victimId'] as String?,
      victimName: d['victimName'] as String?,
      victimColor: d['victimColor'] as String?,
      targetId: d['targetId'] as String? ?? '',
      won: d['won'] as bool? ?? false,
    );
  }
}