import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/game_rules.dart';

/// A player's document under games/{gameId}/players/{uid}.
///
/// Gold is stored idle-style: a snapshot ([gold]) plus when it was taken
/// ([goldUpdatedAt]) and how fast it grows ([goldRate], per second). The
/// current amount is computed with [goldAt], never stored.
class PlayerState {
  final String uid;
  final String displayName;
  final String colorHex;
  final double gold;
  final double goldRate;
  final DateTime? goldUpdatedAt;

  /// When this player last attacked (null = never). Drives the cooldown.
  final DateTime? lastAttackAt;

  /// When this player last destroyed a building (null = never).
  final DateTime? lastDestroyAt;

  const PlayerState({
    required this.uid,
    required this.displayName,
    required this.colorHex,
    required this.gold,
    required this.goldRate,
    required this.goldUpdatedAt,
    this.lastAttackAt,
    this.lastDestroyAt,
  });

  factory PlayerState.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final updated = data['goldUpdatedAt'];
    final lastAttack = data['lastAttackAt'];
    final lastDestroy = data['lastDestroyAt'];
    return PlayerState(
      uid: doc.id,
      displayName: (data['displayName'] as String?) ?? 'Player',
      colorHex: (data['colorHex'] as String?) ?? '#457B9D',
      gold: (data['gold'] as num?)?.toDouble() ?? 0,
      goldRate: (data['goldRate'] as num?)?.toDouble() ?? 0,
      // Null while a server timestamp is still pending right after a write.
      goldUpdatedAt: updated is Timestamp ? updated.toDate() : null,
      lastAttackAt: lastAttack is Timestamp ? lastAttack.toDate() : null,
      lastDestroyAt: lastDestroy is Timestamp ? lastDestroy.toDate() : null,
    );
  }

  /// When the player may attack again (null = right now).
  DateTime? get attackReadyAt => lastAttackAt?.add(GameRules.attackCooldown);

  /// When the player may build again (null = right now).
  DateTime? get buildReadyAt =>
      lastDestroyAt?.add(GameRules.buildCooldownAfterDestroy);

  /// "#RRGGBB" -> Color (opaque).
  Color get color {
    final hex = colorHex.replaceFirst('#', '');
    final value = int.tryParse(hex, radix: 16) ?? 0x457B9D;
    return Color(0xFF000000 | value);
  }

  /// Gold right now: snapshot + rate * seconds since the snapshot.
  /// Elapsed time is clamped at 0 so a device clock that is slightly behind
  /// the server never shows gold going down.
  double goldAt(DateTime now) {
    final since = goldUpdatedAt ?? now;
    final seconds = now.difference(since).inMilliseconds / 1000.0;
    return gold + goldRate * (seconds < 0 ? 0 : seconds);
  }
}