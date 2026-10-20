import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../models/trade_offer.dart';
import 'firestore_service.dart' show GameActionException;
import 'server_clock.dart';

/// Private player-to-player trades: any mix of territories and gold on both
/// sides, sent to ONE player.
///
/// Offers live in games/{gameId}/deals/{offerId} with a `participants` list
/// (creator + receiver). Clients only ever query offers they take part in.
/// An offer lasts [TradeOffer.lifetime]. It can't be accepted once it
/// expired, once a territory changed owner or got a building, or once the
/// creator holds less gold than promised. Accepting is one transaction that
/// moves every territory and all the gold and fixes both players' income.
/// Territories WITH a building can't be traded (so market / refinery income
/// never gets stale). Troops stay on the territory.
class TradeService {
  TradeService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const int maxGold = 10000000;
  static const int maxProvincesPerSide = 12;

  DocumentReference<Map<String, dynamic>> _game(String g) =>
      _db.collection('games').doc(g);
  CollectionReference<Map<String, dynamic>> _offers(String g) =>
      _game(g).collection('deals');
  CollectionReference<Map<String, dynamic>> _provinces(String g) =>
      _game(g).collection('provinces');
  DocumentReference<Map<String, dynamic>> _player(String g, String uid) =>
      _game(g).collection('players').doc(uid);

  /// Only the offers [uid] sent or received. No orderBy, so no composite
  /// index is needed; newest first is sorted here.
  Stream<List<TradeOffer>> watchOffers({
    required String gameId,
    required String uid,
  }) =>
      _offers(gameId)
          .where('participants', arrayContains: uid)
          .snapshots()
          .map((s) {
        final list = [for (final d in s.docs) TradeOffer.fromDoc(d)];
        list.sort((a, b) {
          final x = a.createdAt, y = b.createdAt;
          if (x == null && y == null) return 0;
          if (x == null) return -1; // just created, still pending
          if (y == null) return 1;
          return y.compareTo(x);
        });
        return list;
      });

  /// Client-side check used to grey an offer out. The same rules run again
  /// inside [acceptOffer].
  static TradeProblem? problem(
    TradeOffer o,
    Map<String, ProvinceState> provs,
    Map<String, PlayerState> players,
    DateTime now,
  ) {
    if (o.expiredAt(now)) return TradeProblem.expired;
    TradeProblem? found;
    void check(Iterable<String> ids, String owner) {
      for (final id in ids) {
        final p = provs[id];
        if (p == null || p.ownerId != owner) {
          found ??= TradeProblem.ownerChanged;
        } else if (p.hasBuilding) {
          found ??= TradeProblem.buildingAppeared;
        }
      }
    }

    check(o.giveProvinces, o.fromId);
    check(o.takeProvinces, o.toId);
    if (found != null) return found;
    final creator = players[o.fromId];
    if (creator == null || creator.goldAt(now) < o.giveGold) {
      return TradeProblem.giverShort;
    }
    return null;
  }

  bool _hasBuilding(Map<String, dynamic>? province) {
    final b = province?['building'];
    if (b is! Map) return false;
    final type = b['type'] as String? ?? 'none';
    return type.isNotEmpty && type != 'none';
  }

  int _owned(DocumentSnapshot<Map<String, dynamic>> snap) =>
      (snap.data()?['ownedCount'] as num?)?.toInt() ?? 0;

  double _income(DocumentSnapshot<Map<String, dynamic>> snap) =>
      (snap.data()?['buildingIncome'] as num?)?.toDouble() ?? 0;

  /// Same shape as FirestoreService._settledIncomeUpdate: gold is settled at
  /// the old rate (minus [spend]), then the new counts and rate are stored.
  Map<String, dynamic> _settled(
    DocumentSnapshot<Map<String, dynamic>> snap, {
    required int owned,
    required double income,
    required DateTime now,
    required double spend,
  }) {
    final territories = owned < 0 ? 0 : owned;
    final inc = income < 1e-9 ? 0.0 : income;
    return {
      'gold': PlayerState.fromDoc(snap).goldAt(now) - spend,
      'goldUpdatedAt': FieldValue.serverTimestamp(),
      'ownedCount': territories,
      'buildingIncome': inc,
      'goldRate':
          GameRules.incomeRate(territories: territories, buildingIncome: inc),
    };
  }

  Future<void> createOffer({
    required String gameId,
    required String uid,
    required String toId,
    required List<String> giveProvinces,
    required int giveGold,
    required List<String> takeProvinces,
    required int takeGold,
  }) async {
    if (toId == uid) throw const GameActionException("You can't trade with yourself.");
    if (giveProvinces.isEmpty &&
        takeProvinces.isEmpty &&
        giveGold <= 0 &&
        takeGold <= 0) {
      throw const GameActionException('Add something to the trade.');
    }
    if (giveGold < 0 ||
        takeGold < 0 ||
        giveGold > maxGold ||
        takeGold > maxGold) {
      throw const GameActionException('Gold must be 0 to 10,000,000.');
    }
    if (giveProvinces.length > maxProvincesPerSide ||
        takeProvinces.length > maxProvincesPerSide) {
      throw const GameActionException(
          'At most $maxProvincesPerSide territories per side.');
    }

    final me = await _player(gameId, uid).get();
    final other = await _player(gameId, toId).get();
    if (!me.exists) throw const GameActionException('Player not found.');
    if (!other.exists || _owned(other) <= 0) {
      throw const GameActionException('That player is not in the game.');
    }
    if (PlayerState.fromDoc(me).goldAt(ServerClock.now()) < giveGold) {
      throw const GameActionException('Not enough gold.');
    }
    if (_owned(me) - giveProvinces.length + takeProvinces.length < 1) {
      throw const GameActionException('Keep at least one territory.');
    }
    if (_owned(other) - takeProvinces.length + giveProvinces.length < 1) {
      throw const GameActionException(
          'The other player must keep at least one territory.');
    }

    Future<void> verify(List<String> ids, String owner) async {
      for (final id in ids) {
        final snap = await _provinces(gameId).doc(id).get();
        final data = snap.data();
        if (data?['ownerId'] != owner) {
          throw const GameActionException('A territory changed owner.');
        }
        if (_hasBuilding(data)) {
          throw const GameActionException(
              "Territories with buildings can't be traded.");
        }
      }
    }

    await verify(giveProvinces, uid);
    await verify(takeProvinces, toId);

    await _offers(gameId).add({
      'participants': [uid, toId],
      'fromId': uid,
      'fromName': (me.data()?['displayName'] as String?) ?? 'Player',
      'fromColor': (me.data()?['colorHex'] as String?) ?? '#457B9D',
      'toId': toId,
      'toName': (other.data()?['displayName'] as String?) ?? 'Player',
      'toColor': (other.data()?['colorHex'] as String?) ?? '#457B9D',
      'giveProvinces': giveProvinces,
      'giveGold': giveGold,
      'takeProvinces': takeProvinces,
      'takeGold': takeGold,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Creator cancels, receiver declines, or either clears an old offer.
  Future<void> removeOffer({
    required String gameId,
    required String uid,
    required String offerId,
  }) async {
    final ref = _offers(gameId).doc(offerId);
    final snap = await ref.get();
    final parts = (snap.data()?['participants'] as List?) ?? const [];
    if (parts.contains(uid)) await ref.delete();
  }

  /// The receiver ([uid]) accepts: both sides' territories change hands and
  /// the gold moves, all or nothing.
  Future<void> acceptOffer({
    required String gameId,
    required String uid,
    required String offerId,
  }) async {
    final offerRef = _offers(gameId).doc(offerId);
    final pre = await offerRef.get();
    if (!pre.exists) throw const GameActionException('This offer is gone.');
    final preOffer = TradeOffer.fromDoc(pre);
    final moved = [...preOffer.giveProvinces, ...preOffer.takeProvinces];

    // Markets saved these territories as neighbors. Transactions can't run
    // queries, so find them first and re-read them inside.
    final marketRefs = <String, DocumentReference<Map<String, dynamic>>>{};
    for (final id in moved) {
      final found = await _provinces(gameId)
          .where('building.neighbors', arrayContains: id)
          .get();
      for (final d in found.docs) {
        marketRefs[d.id] = d.reference;
      }
    }

    final error = await _db.runTransaction<String?>((tx) async {
      final offerSnap = await tx.get(offerRef);
      if (!offerSnap.exists) return 'This offer is gone.';
      final offer = TradeOffer.fromDoc(offerSnap);
      if (offer.toId != uid) return 'This offer is not for you.';

      final now = ServerClock.now();
      if (offer.expiredAt(now)) return 'This offer expired.';

      final fromRef = _player(gameId, offer.fromId);
      final toRef = _player(gameId, offer.toId);
      final fromSnap = await tx.get(fromRef);
      final toSnap = await tx.get(toRef);

      final provSnaps = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final id in {...offer.giveProvinces, ...offer.takeProvinces}) {
        provSnaps[id] = await tx.get(_provinces(gameId).doc(id));
      }
      final markets = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in marketRefs.values) {
        markets.add(await tx.get(ref));
      }

      if (!fromSnap.exists || !toSnap.exists) return 'A player has left.';

      String? bad(List<String> ids, String owner) {
        for (final id in ids) {
          final data = provSnaps[id]?.data();
          if (data == null || data['ownerId'] != owner) {
            return 'A territory changed owner.';
          }
          if (_hasBuilding(data)) return 'A territory got a building.';
        }
        return null;
      }

      final problem = bad(offer.giveProvinces, offer.fromId) ??
          bad(offer.takeProvinces, offer.toId);
      if (problem != null) return problem;

      if (PlayerState.fromDoc(fromSnap).goldAt(now) < offer.giveGold) {
        return '${offer.fromName} no longer has enough gold.';
      }
      if (PlayerState.fromDoc(toSnap).goldAt(now) < offer.takeGold) {
        return 'Not enough gold.';
      }

      final nGive = offer.giveProvinces.length;
      final nTake = offer.takeProvinces.length;
      if (_owned(fromSnap) - nGive + nTake < 1) {
        return '${offer.fromName} must keep at least one territory.';
      }
      if (_owned(toSnap) - nTake + nGive < 1) {
        return 'You must keep at least one territory.';
      }

      // Markets next door trade with more / fewer territories. Each market
      // is updated once, with the sum over every moved territory.
      final gain = <String, double>{offer.fromId: 0, offer.toId: 0};
      final loss = <String, double>{offer.fromId: 0, offer.toId: 0};
      final moves = <({String id, String from, String to})>[
        for (final id in offer.giveProvinces)
          (id: id, from: offer.fromId, to: offer.toId),
        for (final id in offer.takeProvinces)
          (id: id, from: offer.toId, to: offer.fromId),
      ];
      final tradeWrites = <DocumentReference<Map<String, dynamic>>, int>{};
      for (final snap in markets) {
        if (!snap.exists) continue;
        final m = snap.data();
        final b = m?['building'];
        if (b is! Map) continue;
        final def = GameRules.buildingById(b['type'] as String? ?? '');
        if (def == null || !def.tradesWithNeighbors || def.suppliedBy.isNotEmpty) {
          continue;
        }
        final neighbors = (b['neighbors'] as List?)?.cast<String>() ?? const [];
        final owner = m?['ownerId'] as String?;
        if (owner != offer.fromId && owner != offer.toId) continue;
        final trades = (b['trades'] as num?)?.toInt() ?? 0;
        var delta = 0;
        for (final mv in moves) {
          if (!neighbors.contains(mv.id)) continue;
          if (owner == mv.to) {
            delta++;
            gain[owner!] = gain[owner]! + def.partnerRateFor(snap.id);
          } else if (owner == mv.from && trades + delta > 0) {
            delta--;
            loss[owner!] = loss[owner]! + def.partnerRateFor(snap.id);
          }
        }
        if (delta != 0) tradeWrites[snap.reference] = trades + delta;
      }

      tradeWrites.forEach((ref, trades) {
        tx.update(ref, {'building.trades': trades});
      });
      for (final id in offer.giveProvinces) {
        tx.update(provSnaps[id]!.reference, {'ownerId': offer.toId});
      }
      for (final id in offer.takeProvinces) {
        tx.update(provSnaps[id]!.reference, {'ownerId': offer.fromId});
      }
      tx.delete(offerRef);
      tx.update(
        fromRef,
        _settled(
          fromSnap,
          owned: _owned(fromSnap) - nGive + nTake,
          income: _income(fromSnap) + gain[offer.fromId]! - loss[offer.fromId]!,
          now: now,
          spend: (offer.giveGold - offer.takeGold).toDouble(),
        ),
      );
      tx.update(
        toRef,
        _settled(
          toSnap,
          owned: _owned(toSnap) - nTake + nGive,
          income: _income(toSnap) + gain[offer.toId]! - loss[offer.toId]!,
          now: now,
          spend: (offer.takeGold - offer.giveGold).toDouble(),
        ),
      );
      return null;
    });

    if (error != null) throw GameActionException(error);
  }
}