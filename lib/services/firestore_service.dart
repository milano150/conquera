import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../config/game_rules.dart';
import '../models/battle_event.dart';
import '../models/log_entry.dart';
import '../models/attack_result.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../models/update_entry.dart';
import 'server_clock.dart';

/// A game action that was refused for a normal reason (not enough gold,
/// not your province, ...). [message] is safe to show to the player.
class GameActionException implements Exception {
  final String message;

  const GameActionException(this.message);

  @override
  String toString() => message;
}

/// All Firestore access for Conquera lives here, so the rest of the app
/// never builds collection paths by hand.
///
/// Layout (see the DB structure we agreed on):
///   games/{gameId}
///   games/{gameId}/players/{uid}
///   games/{gameId}/provinces/{provinceId}
class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _gameRef(String gameId) =>
      _db.collection('games').doc(gameId);

  DocumentReference<Map<String, dynamic>> _playerRef(
    String gameId,
    String uid,
  ) =>
      _gameRef(gameId).collection('players').doc(uid);

  CollectionReference<Map<String, dynamic>> _provincesRef(String gameId) =>
      _gameRef(gameId).collection('provinces');

  /// Live updates of one player's document (null if it doesn't exist yet).
  Stream<PlayerState?> watchPlayer({
    required String gameId,
    required String uid,
  }) {
    return _playerRef(gameId, uid).snapshots().map(
          (snap) => snap.exists ? PlayerState.fromDoc(snap) : null,
        );
  }

  /// Live ownership/state of every province that has a document, keyed by
  /// province id. Provinces missing from the map are neutral.
  Stream<Map<String, ProvinceState>> watchProvinces({required String gameId}) {
    return _provincesRef(gameId).snapshots().map(
          (snap) => {
            for (final doc in snap.docs) doc.id: ProvinceState.fromDoc(doc),
          },
        );
  }

  /// Every attack that gets resolved, so all players can watch it happen.
  /// The first snapshot replays recent history; callers skip old events.
  Stream<BattleEvent> watchBattleEvents({required String gameId}) {
    return _gameRef(gameId)
        .collection('events')
        .orderBy('at', descending: true)
        .limit(5)
        .snapshots()
        .expand(
          (snap) => [
            for (final c in snap.docChanges)
              // The Log shares this collection: only attacks are replayed.
              if (c.type == DocumentChangeType.added &&
                  (c.doc.data()?['type'] ?? 'attack') == 'attack')
                BattleEvent.fromDoc(c.doc),
          ],
        );
  }

  /// The world Log: the latest [limit] public events (annexations, attacks,
  /// joins, eliminations, respawns), oldest first, so the newest is last.
  Stream<List<LogEntry>> watchLog({
    required String gameId,
    int limit = 150,
  }) {
    return _gameRef(gameId)
        .collection('events')
        .orderBy('at', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) {
      final list = [for (final doc in snap.docs.reversed) LogEntry.fromDoc(doc)];
      // An attack and the elimination it caused share a timestamp: keep the
      // attack first. Dart's sort isn't stable, so break ties by hand.
      int rank(LogEntry e) => e.type == LogType.eliminated ? 1 : 0;
      final order = {for (var i = 0; i < list.length; i++) list[i].id: i};
      list.sort((a, b) {
        final at = a.at, bt = b.at;
        final c = at == null && bt == null
            ? 0
            : at == null
                ? 1
                : bt == null
                    ? -1
                    : at.compareTo(bt);
        if (c != 0) return c;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : order[a.id]!.compareTo(order[b.id]!);
      });
      return list;
    });
  }

  /// A player's personal feed (attacks they did or faced, buildings they
  /// built or destroyed): the latest [limit] entries, oldest first, so the
  /// newest is last.
  Stream<List<UpdateEntry>> watchUpdates({
    required String gameId,
    required String uid,
    int limit = 80,
  }) {
    return _playerRef(gameId, uid)
        .collection('updates')
        .orderBy('at', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => [
            for (final doc in snap.docs.reversed) UpdateEntry.fromDoc(doc),
          ],
        );
  }

  /// Live list of every player in the game, keyed by uid (for owner names
  /// and colors).
  Stream<Map<String, PlayerState>> watchPlayers({required String gameId}) {
    return _gameRef(gameId).collection('players').snapshots().map(
          (snap) => {
            for (final doc in snap.docs) doc.id: PlayerState.fromDoc(doc),
          },
        );
  }

  // ---------------------------------------------------------------------
  // Small readers
  // ---------------------------------------------------------------------

  int _ownedCount(DocumentSnapshot<Map<String, dynamic>> playerSnap) =>
      (playerSnap.data()?['ownedCount'] as num?)?.toInt() ?? 0;

  /// Combined gold per second of all the player's buildings.
  double _buildingIncome(DocumentSnapshot<Map<String, dynamic>> playerSnap) =>
      (playerSnap.data()?['buildingIncome'] as num?)?.toDouble() ?? 0;

  /// Gold per second the building on this province makes (0 if none). A
  /// market earns for every bordering territory its owner holds; that count
  /// is kept as 'trades' on the building and updated by [_shiftTrades]
  /// whenever a bordering province changes hands.
  double _buildingIncomeOf(Map<String, dynamic>? provinceData) {
    final building = provinceData?['building'];
    if (building is! Map) return 0;
    final def = GameRules.buildingById(building['type'] as String? ?? '');
    if (def == null) return 0;
    return def.incomeFor((building['trades'] as num?)?.toInt() ?? 0);
  }

  /// A province just changed hands from [fromOwner] (null = nobody) to
  /// [toOwner]. Markets on the bordering provinces ([neighborSnaps]) trade
  /// with one more territory if they belong to [toOwner] and one fewer if
  /// they belong to [fromOwner]. Writes the new 'trades' counts and returns
  /// how much each side's income per second changes by. Call it in the
  /// write phase of a transaction (after every read).
  ({double gain, double loss}) _shiftTrades(
    Transaction tx,
    Iterable<DocumentSnapshot<Map<String, dynamic>>> neighborSnaps, {
    required String? fromOwner,
    required String toOwner,
  }) {
    var gain = 0.0;
    var loss = 0.0;
    for (final snap in neighborSnaps) {
      if (!snap.exists) continue;
      final data = snap.data();
      final building = data?['building'];
      if (building is! Map) continue;
      final def = GameRules.buildingById(building['type'] as String? ?? '');
      if (def == null || !def.tradesWithNeighbors) continue;
      final owner = data?['ownerId'];
      final trades = (building['trades'] as num?)?.toInt() ?? 0;
      if (owner == toOwner) {
        tx.update(snap.reference, {'building.trades': trades + 1});
        gain += def.goldPerPartnerPerSec;
      } else if (fromOwner != null && owner == fromOwner && trades > 0) {
        tx.update(snap.reference, {'building.trades': trades - 1});
        loss += def.goldPerPartnerPerSec;
      }
    }
    return (gain: gain, loss: loss);
  }

  /// Splits [total] power between a newly taken province and the
  /// [holders] provinces that supplied the troops, without losing any:
  /// the shares always add up to exactly [total]. Whole numbers go first and
  /// rounding favors the holders, so 5 power becomes 3 for the attacking
  /// province and 2 for the new one.
  ({double annexed, List<double> holders}) _splitPower(
    double total,
    int holders,
  ) {
    if (holders <= 0) return (annexed: total, holders: const <double>[]);
    // Not enough to go round: nobody is ever left at 0, so each province
    // gets 1 (a few power appear out of thin air in this rare case).
    if (total <= holders + 1) {
      return (annexed: 1, holders: List<double>.filled(holders, 1));
    }
    final annexed = (total / (holders + 1)).floorToDouble();
    final rest = total - annexed;
    final base = (rest / holders).floorToDouble();
    var extra = max(0.0, rest - base * holders);
    final shares = List<double>.filled(holders, base);
    for (var i = 0; i < holders && extra >= 1; i++) {
      shares[i] += 1;
      extra -= 1;
    }
    shares[0] += extra; // any fractional crumbs
    return (annexed: annexed, holders: shares);
  }

  double _troopsOf(DocumentSnapshot<Map<String, dynamic>> snap) =>
      (snap.data()?['troops'] as num?)?.toDouble() ?? 0;

  String _buildingTypeOf(Map<String, dynamic>? provinceData) {
    final building = provinceData?['building'];
    return building is Map ? (building['type'] as String? ?? 'none') : 'none';
  }

  String _nameOf(DocumentSnapshot<Map<String, dynamic>>? snap) =>
      (snap?.data()?['displayName'] as String?) ?? 'Player';

  String _colorOf(DocumentSnapshot<Map<String, dynamic>>? snap) =>
      (snap?.data()?['colorHex'] as String?) ?? '#457B9D';

  /// Adds a line to the world Log (games/{gameId}/events) inside [tx].
  /// [data] needs actorId / actorName / actorColor, plus whatever the type
  /// uses (targetId, victimId, ...).
  void _logEvent(
    Transaction tx,
    String gameId,
    String type,
    Map<String, dynamic> data,
  ) {
    tx.set(_gameRef(gameId).collection('events').doc(), {
      'type': type,
      ...data,
      'at': FieldValue.serverTimestamp(),
    });
  }

  /// The fields to write when a player's income changes: gold is settled
  /// up to [now] at the OLD rate (minus any [spend]), then the new counts
  /// and the rate derived from them are stored. Without settling, changing
  /// the rate would retroactively change gold already earned.
  Map<String, dynamic> _settledIncomeUpdate(
    DocumentSnapshot<Map<String, dynamic>> playerSnap, {
    required int owned,
    required double buildingIncome,
    required DateTime now,
    double spend = 0,
  }) {
    final territories = owned < 0 ? 0 : owned;
    // Repeated adding and subtracting can leave tiny float leftovers.
    final income = buildingIncome < 1e-9 ? 0.0 : buildingIncome;
    return {
      'gold': PlayerState.fromDoc(playerSnap).goldAt(now) - spend,
      'goldUpdatedAt': FieldValue.serverTimestamp(),
      'ownedCount': territories,
      'buildingIncome': income,
      'goldRate': GameRules.incomeRate(
        territories: territories,
        buildingIncome: income,
      ),
    };
  }

  // ---------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------

  /// DEBUG ONLY: makes [uid] the owner of [provinceId], no questions asked.
  /// Real claiming will go through a Cloud Function that checks gold,
  /// adjacency, and so on.
  ///
  /// Ownership changes the income rate (territories, the building on the
  /// province, and markets next door), so each affected player's gold is
  /// settled first and only then given the new rate. All of it happens in
  /// one transaction. Like in an invasion, the building on the province is
  /// lost. [neighborIds] are the bordering provinces, so neighboring markets
  /// can update who they trade with.
  Future<void> claimProvince({
    required String gameId,
    required String provinceId,
    required String uid,
    Iterable<String> neighborIds = const [],
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final newOwnerRef = _playerRef(gameId, uid);
    final neighborRefs = [
      for (final id in neighborIds.toSet())
        if (id != provinceId) _provincesRef(gameId).doc(id),
    ];

    await _db.runTransaction((tx) async {
      // Firestore transactions require every read before any write.
      final provinceSnap = await tx.get(provinceRef);
      final provinceData = provinceSnap.data();
      final previousOwnerId = provinceData?['ownerId'] as String?;
      if (previousOwnerId == uid) return; // already yours

      final incomeDelta = _buildingIncomeOf(provinceData);

      final newOwnerSnap = await tx.get(newOwnerRef);
      DocumentReference<Map<String, dynamic>>? previousOwnerRef;
      DocumentSnapshot<Map<String, dynamic>>? previousOwnerSnap;
      if (previousOwnerId != null) {
        previousOwnerRef = _playerRef(gameId, previousOwnerId);
        previousOwnerSnap = await tx.get(previousOwnerRef);
      }
      final neighborSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in neighborRefs) {
        neighborSnaps.add(await tx.get(ref));
      }

      final now = ServerClock.now();
      final shift = _shiftTrades(
        tx,
        neighborSnaps,
        fromOwner: previousOwnerId,
        toOwner: uid,
      );

      if (provinceSnap.exists) {
        tx.update(provinceRef, {
          'ownerId': uid,
          'building': {'type': 'none', 'level': 0},
        });
      } else {
        tx.set(provinceRef, {
          'ownerId': uid,
          'troops': 1,
          'troopsUpdatedAt': FieldValue.serverTimestamp(),
          'building': {'type': 'none', 'level': 0},
        });
      }

      if (newOwnerSnap.exists) {
        tx.update(
          newOwnerRef,
          _settledIncomeUpdate(
            newOwnerSnap,
            owned: _ownedCount(newOwnerSnap) + 1,
            buildingIncome: _buildingIncome(newOwnerSnap) + shift.gain,
            now: now,
          ),
        );
      }

      if (previousOwnerRef != null &&
          previousOwnerSnap != null &&
          previousOwnerSnap.exists) {
        tx.update(
          previousOwnerRef,
          _settledIncomeUpdate(
            previousOwnerSnap,
            owned: _ownedCount(previousOwnerSnap) - 1,
            buildingIncome:
                _buildingIncome(previousOwnerSnap) - incomeDelta - shift.loss,
            now: now,
          ),
        );
      }
    });
  }

  /// Builds [building] on a province the player owns: pays the price,
  /// puts the building on the province, and raises the player's income if
  /// it makes gold. [neighborIds] are the bordering provinces: a market
  /// starts out trading with the ones the player owns. Throws
  /// [GameActionException] if it isn't allowed,
  /// including when the building doesn't fit the territory (a harbor on a
  /// landlocked country, a rig off an island archipelago).
  ///
  /// NOTE: like [claimProvince], this runs on the client for now. It
  /// should move into a Cloud Function before real players use it.
  Future<void> constructBuilding({
    required String gameId,
    required String provinceId,
    required String uid,
    required BuildingDef building,
    required Iterable<String> neighborIds,
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final playerRef = _playerRef(gameId, uid);
    final neighbors = neighborIds.toSet()..remove(provinceId);
    // Only a market needs to know who the neighbors belong to.
    final neighborRefs = [
      if (building.tradesWithNeighbors)
        for (final id in neighbors) _provincesRef(gameId).doc(id),
    ];

    final error = await _db.runTransaction<String?>((tx) async {
      final provinceSnap = await tx.get(provinceRef);
      final playerSnap = await tx.get(playerRef);
      final neighborSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in neighborRefs) {
        neighborSnaps.add(await tx.get(ref));
      }

      final data = provinceSnap.data();
      if (!provinceSnap.exists || data?['ownerId'] != uid) {
        return "You don't own this province.";
      }
      if (!playerSnap.exists) return 'Player not found.';
      if (_buildingTypeOf(data) != 'none') {
        return 'This province already has a building.';
      }
      if (!GameRules.canBuildHere(
        building,
        provinceId,
        neighbors: neighbors.length,
      )) {
        return "You can't build a ${building.name} in this territory.";
      }

      final now = ServerClock.now();
      final buildReadyAt = PlayerState.fromDoc(playerSnap).buildReadyAt;
      if (buildReadyAt != null && now.isBefore(buildReadyAt)) {
        final secs = (buildReadyAt.difference(now).inMilliseconds / 1000).ceil();
        return 'You can build again in $secs s.';
      }
      final gold = PlayerState.fromDoc(playerSnap).goldAt(now);
      if (gold < building.cost) return 'Not enough gold.';

      // A market trades with the bordering territories the player owns.
      final trades = neighborSnaps
          .where((snap) => snap.exists && snap.data()?['ownerId'] == uid)
          .length;
      final addedIncome = building.incomeFor(trades);

      tx.update(provinceRef, {
        'building': {
          'type': building.id,
          'level': 1,
          if (building.tradesWithNeighbors) ...{
            'neighbors': neighbors.toList(),
            'trades': trades,
          },
        },
      });
      tx.update(
        playerRef,
        _settledIncomeUpdate(
          playerSnap,
          owned: _ownedCount(playerSnap),
          buildingIncome: _buildingIncome(playerSnap) + addedIncome,
          now: now,
          spend: building.cost.toDouble(),
        ),
      );
      tx.set(playerRef.collection('updates').doc(), {
        'type': 'build',
        'provinceId': provinceId,
        'buildingId': building.id,
        'at': FieldValue.serverTimestamp(),
      });
      return null;
    });

    if (error != null) throw GameActionException(error);
  }

  /// Removes the building from a province the player owns. No refund. If it
  /// made gold, the player's income drops accordingly (gold earned so
  /// far is settled first). Throws [GameActionException] if not allowed.
  Future<void> destroyBuilding({
    required String gameId,
    required String provinceId,
    required String uid,
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final playerRef = _playerRef(gameId, uid);

    final error = await _db.runTransaction<String?>((tx) async {
      final provinceSnap = await tx.get(provinceRef);
      final playerSnap = await tx.get(playerRef);

      final data = provinceSnap.data();
      if (!provinceSnap.exists || data?['ownerId'] != uid) {
        return "You don't own this province.";
      }
      if (!playerSnap.exists) return 'Player not found.';
      if (_buildingTypeOf(data) == 'none') {
        return 'There is nothing to destroy here.';
      }

      final removedIncome = _buildingIncomeOf(data);

      tx.update(provinceRef, {
        'building': {'type': 'none', 'level': 0},
      });
      final now = ServerClock.now();
      tx.update(playerRef, {
        ..._settledIncomeUpdate(
          playerSnap,
          owned: _ownedCount(playerSnap),
          buildingIncome: _buildingIncome(playerSnap) - removedIncome,
          now: now,
        ),
        // Starts the "can't build yet" cooldown.
        'lastDestroyAt': Timestamp.fromDate(now),
      });
      tx.set(playerRef.collection('updates').doc(), {
        'type': 'destroy',
        'provinceId': provinceId,
        'buildingId': _buildingTypeOf(data),
        'at': FieldValue.serverTimestamp(),
      });
      return null;
    });

    if (error != null) throw GameActionException(error);
  }

  /// Buys [unit] for a province the player owns and adds its power to the
  /// province's troops. Income doesn't change, so only gold is settled.
  /// Throws [GameActionException] if it isn't allowed.
  Future<void> recruitTroops({
    required String gameId,
    required String provinceId,
    required String uid,
    required UnitDef unit,
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final playerRef = _playerRef(gameId, uid);

    final error = await _db.runTransaction<String?>((tx) async {
      final provinceSnap = await tx.get(provinceRef);
      final playerSnap = await tx.get(playerRef);

      final data = provinceSnap.data();
      if (!provinceSnap.exists || data?['ownerId'] != uid) {
        return "You don't own this province.";
      }
      if (!playerSnap.exists) return 'Player not found.';

      final now = ServerClock.now();
      final gold = PlayerState.fromDoc(playerSnap).goldAt(now);
      if (gold < unit.cost) return 'Not enough gold.';

      final troops = (data?['troops'] as num?)?.toDouble() ?? 0;

      tx.update(provinceRef, {
        'troops': troops + unit.power,
        'troopsUpdatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(playerRef, {
        'gold': gold - unit.cost,
        'goldUpdatedAt': FieldValue.serverTimestamp(),
      });
      return null;
    });

    if (error != null) throw GameActionException(error);
  }

  /// [uid] attacks [targetId].
  ///
  /// Who fights: every province [uid] owns among [neighborIds] (the target's
  /// bordering provinces), plus every barracks province [uid] owns that
  /// borders one of those. A province with only 1 power ([GameRules.canAct])
  /// never fights: it is left untouched, though it still counts as a
  /// bordering province that a barracks can link to. [supportLinks] maps each candidate barracks
  /// province to the provinces it borders (worked out from the map geometry
  /// by the caller); the transaction re-checks ownership and the building.
  ///
  /// Attacker power X = the troops of everyone fighting added together;
  /// defender power Y = the target's troops (times 1.5 if it has a fortress)
  /// plus the troops of the defender's barracks that border the target.
  /// No luck: if X > Y the attacker wins, otherwise (a tie included) the
  /// defender holds.
  ///
  /// Win: the leftover X - Y is normalized: split equally between every
  /// province that fought and the annexed province (which changes hands),
  /// except barracks, which only supplied troops and end up empty. Any
  /// building on the annexed province is destroyed.
  /// The defending barracks lose all their troops. Loss: everyone who fought
  /// loses [GameRules.failedAttackLossShare] of their troops, and the
  /// defence loses the same total amount, spread over the target and its
  /// barracks in proportion to their troops.
  /// Either way the attacker's cooldown starts.
  ///
  /// Throws [GameActionException] if the attack isn't allowed.
  ///
  /// NOTE: runs on the client for now, like the other actions. Move it into
  /// a Cloud Function (with its own border check) before real players.
  Future<AttackResult> attackProvince({
    required String gameId,
    required String uid,
    required String targetId,
    required Iterable<String> neighborIds,
    Map<String, Set<String>> supportLinks = const {},
  }) async {
    final targetRef = _provincesRef(gameId).doc(targetId);
    final attackerRef = _playerRef(gameId, uid);
    final borderIds = neighborIds.toSet()..remove(targetId);
    final borderRefs = [
      for (final id in borderIds) _provincesRef(gameId).doc(id),
    ];
    final supportIds = [
      for (final id in supportLinks.keys)
        if (id != targetId && !borderIds.contains(id)) id,
    ];
    final supportRefs = [
      for (final id in supportIds) _provincesRef(gameId).doc(id),
    ];

    AttackResult? result;
    String? error;
    // Territories involved, with troops before and after (for the Updates
    // feed of both players).
    final attackerRows = <Map<String, dynamic>>[];
    final defenderRows = <Map<String, dynamic>>[];

    await _db.runTransaction<void>((tx) async {
      result = null;
      error = null;
      attackerRows.clear();
      defenderRows.clear();

      // Every read first, then the writes.
      final targetSnap = await tx.get(targetRef);
      final attackerSnap = await tx.get(attackerRef);
      final borderSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in borderRefs) {
        borderSnaps.add(await tx.get(ref));
      }
      final supportSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in supportRefs) {
        supportSnaps.add(await tx.get(ref));
      }

      final targetData = targetSnap.data();
      final defenderId = targetData?['ownerId'] as String?;
      DocumentReference<Map<String, dynamic>>? defenderRef;
      DocumentSnapshot<Map<String, dynamic>>? defenderSnap;
      if (defenderId != null && defenderId != uid) {
        defenderRef = _playerRef(gameId, defenderId);
        defenderSnap = await tx.get(defenderRef);
      }

      if (!attackerSnap.exists) {
        error = 'Player not found.';
        return;
      }
      if (defenderId == null) {
        error = "This province isn't owned by another player.";
        return;
      }
      if (defenderId == uid) {
        error = "You can't attack your own province.";
        return;
      }

      final now = ServerClock.now();
      final readyAt = PlayerState.fromDoc(attackerSnap).attackReadyAt;
      if (readyAt != null && now.isBefore(readyAt)) {
        final secs = (readyAt.difference(now).inMilliseconds / 1000).ceil();
        error = 'Your troops are still recovering '
            '(${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')} left).';
        return;
      }

      final bordering = [
        for (final snap in borderSnaps)
          if (snap.exists && snap.data()?['ownerId'] == uid) snap,
      ];
      if (bordering.isEmpty) {
        error = 'None of your provinces border this one.';
        return;
      }

      // Barracks that border a fighting province send their power too.
      final borderingIds = {for (final snap in bordering) snap.id};
      final supporters = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (var i = 0; i < supportSnaps.length; i++) {
        final snap = supportSnaps[i];
        final data = snap.data();
        if (!snap.exists || data?['ownerId'] != uid) continue;
        if (!GameRules.supportsAttacks(_buildingTypeOf(data))) continue;
        if (!GameRules.canAct(_troopsOf(snap))) continue;
        final links = supportLinks[supportIds[i]] ?? const <String>{};
        if (links.any(borderingIds.contains)) supporters.add(snap);
      }
      // Provinces with only 1 power can't attack; they stay as they are.
      final fighters = [
        for (final snap in bordering)
          if (GameRules.canFight(_troopsOf(snap), _buildingTypeOf(snap.data())))
            snap,
        ...supporters,
      ];
      if (fighters.isEmpty) {
        error = "Provinces with only 1 power or a wall can't attack.";
        return;
      }

      var attackerPower = 0.0;
      for (final snap in fighters) {
        attackerPower += _troopsOf(snap);
      }

      // The defender's barracks that border the target send their troops to
      // defend it (the mirror of the attacker's barracks).
      final defenderSupporters = [
        for (final snap in borderSnaps)
          if (snap.exists &&
              snap.data()?['ownerId'] == defenderId &&
              GameRules.supportsAttacks(_buildingTypeOf(snap.data())))
            snap,
      ];
      var supportPower = 0.0;
      for (final snap in defenderSupporters) {
        supportPower += (snap.data()?['troops'] as num?)?.toDouble() ?? 0;
      }

      final defenseMultiplier =
          GameRules.defenseMultiplier(_buildingTypeOf(targetData));
      final defenderRaw = (targetData?['troops'] as num?)?.toDouble() ?? 0;
      // The fortress bonus only applies to the target's own troops.
      final defenderPower = defenderRaw * defenseMultiplier + supportPower;

      // Pure subtraction, no luck. A tie goes to the defender.
      final won = attackerPower > defenderPower;

      final attackedAt = Timestamp.fromDate(now);
      final stamp = FieldValue.serverTimestamp();

      if (won) {
        // What is left after the fight (X - Y) is normalized: split equally
        // between the fighting provinces and the annexed one. Barracks are
        // left out of the split; their troops were pooled into the attack,
        // so they end up empty.
        // Every fighting province, barracks included, shares the leftover
        // with the annexed province: whole numbers, nothing lost, rounding
        // favors the attackers (5 power -> 3 stay, 2 go to the new province).
        final leftover = attackerPower - defenderPower;
        final split = _splitPower(leftover, fighters.length);
        final shareOf = {
          for (var i = 0; i < fighters.length; i++)
            fighters[i].id: split.holders[i],
        };
        final annexedTroops = split.annexed;
        for (final snap in fighters) {
          tx.update(snap.reference, {
            'troops': shareOf[snap.id] ?? 1,
            'troopsUpdatedAt': stamp,
          });
          attackerRows.add({
            'id': snap.id,
            'before': _troopsOf(snap),
            'after': shareOf[snap.id] ?? 1,
          });
        }
        defenderRows.add({
          'id': targetId,
          'before': defenderRaw,
          'after': annexedTroops,
          'target': true,
        });
        // The defending barracks committed everything and lost it, except
        // for 1 power: a province is never left at 0.
        for (final snap in defenderSupporters) {
          tx.update(snap.reference, {'troops': 1, 'troopsUpdatedAt': stamp});
          defenderRows.add({
            'id': snap.id,
            'before': _troopsOf(snap),
            'after': 1,
          });
        }

        // The building does not survive the invasion. Its income is
        // therefore lost by the defender and never gained by the attacker.
        final hadBuilding = _buildingTypeOf(targetData) != 'none';
        final incomeDelta = _buildingIncomeOf(targetData);
        // Markets next door: the attacker's trade with one more territory,
        // the defender's with one fewer.
        final shift = _shiftTrades(
          tx,
          borderSnaps,
          fromOwner: defenderId,
          toOwner: uid,
        );
        tx.update(targetRef, {
          'ownerId': uid,
          'troops': annexedTroops,
          'troopsUpdatedAt': stamp,
          'building': {'type': 'none', 'level': 0},
        });
        tx.update(attackerRef, {
          ..._settledIncomeUpdate(
            attackerSnap,
            owned: _ownedCount(attackerSnap) + 1,
            buildingIncome: _buildingIncome(attackerSnap) + shift.gain,
            now: now,
          ),
          'lastAttackAt': attackedAt,
        });
        if (defenderRef != null && defenderSnap != null && defenderSnap.exists) {
          tx.update(
            defenderRef,
            _settledIncomeUpdate(
              defenderSnap,
              owned: _ownedCount(defenderSnap) - 1,
              buildingIncome:
                  _buildingIncome(defenderSnap) - incomeDelta - shift.loss,
              now: now,
            ),
          );
        }

        result = AttackResult(
          won: true,
          attackerPower: attackerPower,
          defenderPower: defenderPower,
          fighterIds: [for (final s in fighters) s.id],
          defenderSupportIds: [for (final s in defenderSupporters) s.id],
          powerAfter: leftover,
          defenderPowerLeft: 0,
          buildingDestroyed: hadBuilding,
        );
      } else {
        // Every fighter loses a share of its troops (75%); the defence loses
        // the same total amount, spread over the target and the supporting
        // barracks in proportion to what each one had (so a fortress doesn't
        // inflate what is left).
        final lost = attackerPower * GameRules.failedAttackLossShare;
        final remaining = max(0.0, defenderPower - lost);
        final keep = defenderPower <= 0 ? 0.0 : remaining / defenderPower;
        final left = max(1.0, defenderRaw * keep);
        // Every fighting province keeps at least 1 power. The rest of the
        // survivors (25% of everything that attacked) pull back into the
        // strongest provinces first, each keeping at most what it had.
        var spare = max(0.0, attackerPower - lost - fighters.length);
        final byStrength = [...fighters]
          ..sort((a, b) => _troopsOf(b).compareTo(_troopsOf(a)));
        for (final snap in byStrength) {
          final had = _troopsOf(snap);
          final extra = min(spare, max(0.0, had - 1));
          spare -= extra;
          tx.update(snap.reference, {
            'troops': 1 + extra,
            'troopsUpdatedAt': stamp,
          });
          attackerRows.add({
            'id': snap.id,
            'before': had,
            'after': 1 + extra,
          });
        }
        for (final snap in defenderSupporters) {
          final had = (snap.data()?['troops'] as num?)?.toDouble() ?? 0;
          tx.update(snap.reference, {
            'troops': max(1.0, had * keep),
            'troopsUpdatedAt': stamp,
          });
          defenderRows.add({
            'id': snap.id,
            'before': had,
            'after': max(1.0, had * keep),
          });
        }
        tx.update(targetRef, {'troops': left, 'troopsUpdatedAt': stamp});
        defenderRows.insert(0, {
          'id': targetId,
          'before': defenderRaw,
          'after': left,
          'target': true,
        });
        tx.update(attackerRef, {'lastAttackAt': attackedAt});

        result = AttackResult(
          won: false,
          attackerPower: attackerPower,
          defenderPower: defenderPower,
          fighterIds: [for (final s in fighters) s.id],
          defenderSupportIds: [for (final s in defenderSupporters) s.id],
          powerAfter: attackerPower - lost,
          defenderPowerLeft: left,
        );
      }

      // Tell everyone in the game, so they can watch the invasion too.
      final r = result;
      if (r != null) {
        tx.set(_gameRef(gameId).collection('events').doc(), {
          'type': 'attack',
          'actorId': uid,
          'actorName': _nameOf(attackerSnap),
          'actorColor': _colorOf(attackerSnap),
          'attackerId': uid,
          'defenderId': defenderId,
          'targetId': targetId,
          'won': r.won,
          'fighterIds': r.fighterIds,
          'defenderSupportIds': r.defenderSupportIds,
          'at': FieldValue.serverTimestamp(),
        });

        // Losing the last territory removes the defender from the map.
        if (r.won &&
            defenderSnap != null &&
            defenderSnap.exists &&
            _ownedCount(defenderSnap) - 1 <= 0) {
          _logEvent(tx, gameId, 'eliminated', {
            'actorId': uid,
            'actorName': _nameOf(attackerSnap),
            'actorColor': _colorOf(attackerSnap),
            'victimId': defenderId,
            'victimName': _nameOf(defenderSnap),
            'victimColor': _colorOf(defenderSnap),
            'targetId': targetId,
          });
        }

        // The same report goes into both players' personal Updates feed.
        final report = {
          'type': 'attack',
          'attackerId': uid,
          'defenderId': defenderId,
          'targetId': targetId,
          'won': r.won,
          'attackerPower': attackerPower,
          'defenderPower': defenderPower,
          'defenseMultiplier': defenseMultiplier,
          'targetBuilding': _buildingTypeOf(targetData),
          'attackers': attackerRows,
          'defenders': defenderRows,
          'at': FieldValue.serverTimestamp(),
        };
        tx.set(attackerRef.collection('updates').doc(), report);
        tx.set(_playerRef(gameId, defenderId).collection('updates').doc(), report);
      }
    });

    final failure = error;
    if (failure != null) throw GameActionException(failure);
    final outcome = result;
    if (outcome == null) throw const GameActionException('Attack failed.');
    return outcome;
  }

  /// Buys a bordering unclaimed province for [GameRules.claimCost] gold.
  /// [neighborIds] are the province's bordering provinces (from the map
  /// geometry plus sea links); at least one must belong to [uid]. Claiming
  /// neither waits for nor starts the attack cooldown. Throws
  /// [GameActionException] if it isn't allowed.
  ///
  /// Provinces with only 1 power can't claim. The new province's power comes
  /// from the bordering non-barracks provinces with 2+ power (they split
  /// equally with it). If there are none, a bordering barracks with 2+ power
  /// gives it 1 power and keeps the rest (10 becomes 9). With neither, the
  /// claim is refused.
  ///
  /// NOTE: runs on the client for now, like the other actions.
  Future<void> claimUnclaimedProvince({
    required String gameId,
    required String uid,
    required String provinceId,
    required Iterable<String> neighborIds,
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final playerRef = _playerRef(gameId, uid);
    final borderRefs = [
      for (final id in neighborIds.toSet())
        if (id != provinceId) _provincesRef(gameId).doc(id),
    ];

    final error = await _db.runTransaction<String?>((tx) async {
      final provinceSnap = await tx.get(provinceRef);
      final playerSnap = await tx.get(playerRef);
      final borderSnaps = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final ref in borderRefs) {
        borderSnaps.add(await tx.get(ref));
      }

      final data = provinceSnap.data();
      if (!playerSnap.exists) return 'Player not found.';
      if (data?['ownerId'] != null) return 'This province is already owned.';

      final now = ServerClock.now();
      final player = PlayerState.fromDoc(playerSnap);

      final bordersMine = borderSnaps.any(
        (snap) => snap.exists && snap.data()?['ownerId'] == uid,
      );
      if (!bordersMine) return 'None of your provinces border this one.';

      // Only provinces with 2+ power can claim (1 power stays as garrison).
      final sharing = [
        for (final snap in borderSnaps)
          if (snap.exists &&
              snap.data()?['ownerId'] == uid &&
              !GameRules.supportsAttacks(_buildingTypeOf(snap.data())) &&
              GameRules.canFight(_troopsOf(snap), _buildingTypeOf(snap.data())))
            snap,
      ];
      // No such province: a bordering barracks can pay for the claim instead.
      DocumentSnapshot<Map<String, dynamic>>? barracks;
      if (sharing.isEmpty) {
        for (final snap in borderSnaps) {
          if (!snap.exists ||
              snap.data()?['ownerId'] != uid ||
              !GameRules.supportsAttacks(_buildingTypeOf(snap.data())) ||
              !GameRules.canAct(_troopsOf(snap))) {
            continue;
          }
          if (barracks == null || _troopsOf(snap) > _troopsOf(barracks)) {
            barracks = snap;
          }
        }
        if (barracks == null) return "Provinces with only 1 power can't claim.";
      }

      final cost = GameRules.claimCost;
      if (player.goldAt(now) < cost) return 'Not enough gold.';

      final stamp = FieldValue.serverTimestamp();
      final double share;
      if (barracks != null) {
        // The barracks keeps everything except the 1 power it hands over.
        share = 1;
        tx.update(barracks.reference, {
          'troops': _troopsOf(barracks) - 1,
          'troopsUpdatedAt': stamp,
        });
      } else {
        // Normalize troops: the claiming provinces and the new province
        // share their troops equally. Everyone has 2+ power, so each ends
        // up with at least 1.
        var pool = 0.0;
        for (final snap in sharing) {
          pool += _troopsOf(snap);
        }
        final split = _splitPower(pool, sharing.length);
        share = split.annexed;
        for (var i = 0; i < sharing.length; i++) {
          tx.update(sharing[i].reference, {
            'troops': split.holders[i],
            'troopsUpdatedAt': stamp,
          });
        }
      }

      if (provinceSnap.exists) {
        tx.update(provinceRef, {
          'ownerId': uid,
          'troops': share,
          'troopsUpdatedAt': stamp,
        });
      } else {
        tx.set(provinceRef, {
          'ownerId': uid,
          'troops': share,
          'troopsUpdatedAt': stamp,
          'building': {'type': 'none', 'level': 0},
        });
      }
      // Markets next door now trade with the new territory.
      final shift = _shiftTrades(
        tx,
        borderSnaps,
        fromOwner: null,
        toOwner: uid,
      );
      tx.update(playerRef, {
        ..._settledIncomeUpdate(
          playerSnap,
          owned: _ownedCount(playerSnap) + 1,
          buildingIncome:
              _buildingIncome(playerSnap) + _buildingIncomeOf(data) + shift.gain,
          now: now,
          spend: cost.toDouble(),
        ),
      });
      _logEvent(tx, gameId, 'annex', {
        'actorId': uid,
        'actorName': _nameOf(playerSnap),
        'actorColor': _colorOf(playerSnap),
        'targetId': provinceId,
      });
      return null;
    });

    if (error != null) throw GameActionException(error);
  }

  // ---------------------------------------------------------------------
  // Join / reconcile
  // ---------------------------------------------------------------------

  /// Recounts the player's provinces and the income of their buildings and
  /// fixes ownedCount / buildingIncome / goldRate if they have drifted (or
  /// were created under an older income rule, or the numbers in [GameRules]
  /// changed). Runs on every launch, so stored income always matches
  /// ownership.
  Future<void> _reconcileTerritoryIncome({
    required String gameId,
    required String uid,
  }) async {
    final ref = _playerRef(gameId, uid);
    final snap = await ref.get();
    final data = snap.data();
    if (data == null) return;

    final ownedDocs =
        await _provincesRef(gameId).where('ownerId', isEqualTo: uid).get();
    final owned = ownedDocs.docs.length;
    final ownedIds = {for (final doc in ownedDocs.docs) doc.id};

    // Markets earn for the bordering territories the player owns right now,
    // so their 'trades' count is recomputed too.
    final batch = _db.batch();
    var tradeFixes = 0;
    var income = 0.0;
    for (final doc in ownedDocs.docs) {
      final docData = doc.data();
      final building = docData['building'];
      if (building is Map) {
        final def = GameRules.buildingById(building['type'] as String? ?? '');
        if (def != null && def.tradesWithNeighbors) {
          final neighbors =
              (building['neighbors'] as List?)?.cast<String>() ?? const [];
          final trades = neighbors.where(ownedIds.contains).length;
          if (trades != ((building['trades'] as num?)?.toInt() ?? 0)) {
            batch.update(doc.reference, {'building.trades': trades});
            tradeFixes++;
          }
          income += def.incomeFor(trades);
          continue;
        }
      }
      income += _buildingIncomeOf(docData);
    }
    if (tradeFixes > 0) await batch.commit();

    final storedCount = (data['ownedCount'] as num?)?.toInt();
    final storedIncome = (data['buildingIncome'] as num?)?.toDouble();
    final storedRate = (data['goldRate'] as num?)?.toDouble();
    final expectedRate =
        GameRules.incomeRate(territories: owned, buildingIncome: income);
    final inSync = storedCount == owned &&
        storedIncome != null &&
        (storedIncome - income).abs() < 1e-9 &&
        storedRate != null &&
        (storedRate - expectedRate).abs() < 1e-9;
    if (inSync) return;

    await ref.update(
      _settledIncomeUpdate(
        snap,
        owned: owned,
        buildingIncome: income,
        now: ServerClock.now(),
      ),
    );
    debugPrint('Income reconciled: $owned territories, '
        '${income.toStringAsFixed(4)} gold/s from buildings');
  }

  /// True if a world with this id exists. Worlds are created by hand in the
  /// database; the app never creates one.
  Future<bool> worldExists(String gameId) async {
    final snap = await _gameRef(gameId).get();
    return snap.exists;
  }

  /// True if [uid] has already joined the world (picked a name and color).
  Future<bool> playerExists({
    required String gameId,
    required String uid,
  }) async {
    final snap = await _playerRef(gameId, uid).get();
    return snap.exists;
  }

  /// Re-checks a returning player's territory count and building income
  /// against the provinces they actually own, fixing the income rate if it
  /// drifted.
  Future<void> reconcileIncome({
    required String gameId,
    required String uid,
  }) =>
      _reconcileTerritoryIncome(gameId: gameId, uid: uid);

  /// The attack that took [uid]'s most recent territory: the newest entry in
  /// their feed that was a won attack against them. Null if there is none.
  Future<UpdateEntry?> lastInvasion({
    required String gameId,
    required String uid,
  }) async {
    final snap = await _playerRef(gameId, uid)
        .collection('updates')
        .orderBy('at', descending: true)
        .limit(30)
        .get();
    for (final doc in snap.docs) {
      final entry = UpdateEntry.fromDoc(doc);
      if (entry.type == UpdateType.attack &&
          entry.won &&
          entry.defenderId == uid) {
        return entry;
      }
    }
    return null;
  }

  /// Puts a player who lost every territory back into the world: a random
  /// free country from [spawnCandidates], with [GameRules.startingTroops]
  /// power, and their gold reset to [GameRules.startingGold]. Returns the id
  /// of that country.
  ///
  /// Throws [GameActionException] if the player still owns a territory, never
  /// joined this world, or no candidate is free.
  Future<String> respawn({
    required String gameId,
    required String uid,
    required List<String> spawnCandidates,
  }) async {
    final playerRef = _playerRef(gameId, uid);

    final stillOwns = await _provincesRef(gameId)
        .where('ownerId', isEqualTo: uid)
        .limit(1)
        .get();
    if (stillOwns.docs.isNotEmpty) {
      throw const GameActionException('You still own a territory.');
    }

    final candidates = [...spawnCandidates]..shuffle();
    for (final provinceId in candidates) {
      final provinceRef = _provincesRef(gameId).doc(provinceId);

      final spawned = await _db.runTransaction<bool>((tx) async {
        final playerSnap = await tx.get(playerRef);
        if (!playerSnap.exists) {
          throw const GameActionException('You have not joined this world.');
        }
        final provinceSnap = await tx.get(provinceRef);
        if (provinceSnap.exists && provinceSnap.data()?['ownerId'] != null) {
          return false; // taken, try the next one
        }

        tx.set(provinceRef, {
          'ownerId': uid,
          'troops': GameRules.startingTroops,
          'troopsUpdatedAt': FieldValue.serverTimestamp(),
          'building': {'type': 'none', 'level': 0},
        });
        _logEvent(tx, gameId, 'respawn', {
          'actorId': uid,
          'actorName': _nameOf(playerSnap),
          'actorColor': _colorOf(playerSnap),
          'targetId': provinceId,
        });
        tx.update(playerRef, {
          'gold': GameRules.startingGold.toDouble(),
          'goldUpdatedAt': FieldValue.serverTimestamp(),
          'ownedCount': 1,
          'buildingIncome': 0.0,
          'goldRate': GameRules.incomeRate(territories: 1, buildingIncome: 0),
        });
        return true;
      });

      if (spawned) return provinceId;
    }
    throw const GameActionException('There is no free country to respawn in.');
  }

  /// Removes a player who lost every territory from the world for good by
  /// deleting their player document. They can join again later as a new
  /// player.
  ///
  /// Throws [GameActionException] if the player still owns a territory.
  Future<void> quitWorld({
    required String gameId,
    required String uid,
  }) async {
    final stillOwns = await _provincesRef(gameId)
        .where('ownerId', isEqualTo: uid)
        .limit(1)
        .get();
    if (stillOwns.docs.isNotEmpty) {
      throw const GameActionException('You still own a territory.');
    }
    await _playerRef(gameId, uid).delete();
  }

  /// Adds a new player to an existing world: creates their document with
  /// [GameRules.startingGold] and gives them a random free country from
  /// [spawnCandidates] (province ids) as their starting territory. Returns
  /// the id of that country.
  ///
  /// A candidate someone else owns by the time the transaction runs is
  /// skipped. Throws [GameActionException] if the player already joined or
  /// no candidate is free.
  Future<String> joinWorld({
    required String gameId,
    required String uid,
    required String displayName,
    required String colorHex,
    required List<String> spawnCandidates,
  }) async {
    final playerRef = _playerRef(gameId, uid);
    final candidates = [...spawnCandidates]..shuffle();

    // A color belongs to the first player who picked it in this world.
    final taken = await _gameRef(gameId)
        .collection('players')
        .where('colorHex', isEqualTo: colorHex)
        .limit(1)
        .get();
    if (taken.docs.isNotEmpty && taken.docs.first.id != uid) {
      throw const GameActionException('That color is already taken.');
    }

    for (final provinceId in candidates) {
      final provinceRef = _provincesRef(gameId).doc(provinceId);

      final spawned = await _db.runTransaction<bool>((tx) async {
        final playerSnap = await tx.get(playerRef);
        if (playerSnap.exists) {
          throw const GameActionException('You already joined this world.');
        }
        final provinceSnap = await tx.get(provinceRef);
        if (provinceSnap.exists && provinceSnap.data()?['ownerId'] != null) {
          return false; // taken, try the next one
        }

        tx.set(provinceRef, {
          'ownerId': uid,
          'troops': GameRules.startingTroops,
          'troopsUpdatedAt': FieldValue.serverTimestamp(),
          'building': {'type': 'none', 'level': 0},
        });
        _logEvent(tx, gameId, 'join', {
          'actorId': uid,
          'actorName': displayName,
          'actorColor': colorHex,
        });
        tx.set(playerRef, {
          'displayName': displayName,
          'colorHex': colorHex,
          'joinedAt': FieldValue.serverTimestamp(),
          // Idle-style resource: a snapshot plus the time it was taken.
          'gold': GameRules.startingGold.toDouble(),
          'goldUpdatedAt': FieldValue.serverTimestamp(),
          'ownedCount': 1,
          'buildingIncome': 0.0,
          'goldRate': GameRules.incomeRate(territories: 1, buildingIncome: 0),
        });
        return true;
      });

      if (spawned) return provinceId;
    }
    throw const GameActionException('There is no free country to start in.');
  }
}