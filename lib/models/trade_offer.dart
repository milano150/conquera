import 'package:cloud_firestore/cloud_firestore.dart';

/// Why an offer can't be accepted right now. Null means it can.
enum TradeProblem { expired, ownerChanged, buildingAppeared, giverShort }

/// A private offer between two players, read from
/// games/{gameId}/deals/{offerId}.
///
/// Written from the creator's point of view: the creator ([fromId]) gives
/// [giveProvinces] + [giveGold] and takes [takeProvinces] + [takeGold] from
/// the receiver ([toId]).
class TradeOffer {
  /// How long an offer stays open.
  static const Duration lifetime = Duration(hours: 12);

  final String id;
  final String fromId;
  final String fromName;
  final String fromColor;
  final String toId;
  final String toName;
  final String toColor;
  final List<String> giveProvinces;
  final int giveGold;
  final List<String> takeProvinces;
  final int takeGold;
  final DateTime? createdAt;

  const TradeOffer({
    required this.id,
    required this.fromId,
    required this.fromName,
    required this.fromColor,
    required this.toId,
    required this.toName,
    required this.toColor,
    required this.giveProvinces,
    required this.giveGold,
    required this.takeProvinces,
    required this.takeGold,
    this.createdAt,
  });

  factory TradeOffer.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? const <String, dynamic>{};
    final at = d['createdAt'];
    List<String> ids(String key) =>
        (d[key] as List?)?.whereType<String>().toList() ?? const [];
    return TradeOffer(
      id: doc.id,
      fromId: (d['fromId'] as String?) ?? '',
      fromName: (d['fromName'] as String?) ?? 'Player',
      fromColor: (d['fromColor'] as String?) ?? '#457B9D',
      toId: (d['toId'] as String?) ?? '',
      toName: (d['toName'] as String?) ?? 'Player',
      toColor: (d['toColor'] as String?) ?? '#457B9D',
      giveProvinces: ids('giveProvinces'),
      giveGold: (d['giveGold'] as num?)?.toInt() ?? 0,
      takeProvinces: ids('takeProvinces'),
      takeGold: (d['takeGold'] as num?)?.toInt() ?? 0,
      createdAt: at is Timestamp ? at.toDate() : null,
    );
  }

  /// Null while the server timestamp is still pending (just created).
  DateTime? get expiresAt => createdAt?.add(lifetime);

  bool expiredAt(DateTime now) {
    final end = expiresAt;
    return end != null && !now.isBefore(end);
  }

  Duration timeLeft(DateTime now) {
    final end = expiresAt;
    if (end == null) return lifetime;
    final left = end.difference(now);
    return left.isNegative ? Duration.zero : left;
  }
}