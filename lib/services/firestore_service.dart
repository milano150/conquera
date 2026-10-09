import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';

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

  /// One shared world for now.
  static const String defaultGameId = 'main';

  /// Small fixed palette; a player's color is picked from it by uid so it
  /// stays the same every time they join.
  static const List<String> _playerColors = [
    '#E63946',
    '#2A9D8F',
    '#457B9D',
    '#E9A23B',
    '#7B2CBF',
    '#F4A261',
  ];

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

  int _mineCount(DocumentSnapshot<Map<String, dynamic>> playerSnap) =>
      (playerSnap.data()?['mineCount'] as num?)?.toInt() ?? 0;

  bool _hasGoldMine(Map<String, dynamic>? provinceData) {
    final building = provinceData?['building'];
    return building is Map && building['type'] == GameRules.goldMine.id;
  }

  String _buildingTypeOf(Map<String, dynamic>? provinceData) {
    final building = provinceData?['building'];
    return building is Map ? (building['type'] as String? ?? 'none') : 'none';
  }

  /// The fields to write when a player's income changes: gold is settled
  /// up to [now] at the OLD rate (minus any [spend]), then the new counts
  /// and the rate derived from them are stored. Without settling, changing
  /// the rate would retroactively change gold already earned.
  Map<String, dynamic> _settledIncomeUpdate(
    DocumentSnapshot<Map<String, dynamic>> playerSnap, {
    required int owned,
    required int mines,
    required DateTime now,
    double spend = 0,
  }) {
    final territories = owned < 0 ? 0 : owned;
    final goldMines = mines < 0 ? 0 : mines;
    return {
      'gold': PlayerState.fromDoc(playerSnap).goldAt(now) - spend,
      'goldUpdatedAt': FieldValue.serverTimestamp(),
      'ownedCount': territories,
      'mineCount': goldMines,
      'goldRate': GameRules.incomeRate(
        territories: territories,
        goldMines: goldMines,
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
  /// Ownership changes the income rate (territories, and the gold mine on
  /// the province if it has one), so each affected player's gold is
  /// settled first and only then given the new rate. All of it happens in
  /// one transaction.
  Future<void> claimProvince({
    required String gameId,
    required String provinceId,
    required String uid,
  }) async {
    final provinceRef = _provincesRef(gameId).doc(provinceId);
    final newOwnerRef = _playerRef(gameId, uid);

    await _db.runTransaction((tx) async {
      // Firestore transactions require every read before any write.
      final provinceSnap = await tx.get(provinceRef);
      final provinceData = provinceSnap.data();
      final previousOwnerId = provinceData?['ownerId'] as String?;
      if (previousOwnerId == uid) return; // already yours

      final mineDelta = _hasGoldMine(provinceData) ? 1 : 0;

      final newOwnerSnap = await tx.get(newOwnerRef);
      DocumentReference<Map<String, dynamic>>? previousOwnerRef;
      DocumentSnapshot<Map<String, dynamic>>? previousOwnerSnap;
      if (previousOwnerId != null) {
        previousOwnerRef = _playerRef(gameId, previousOwnerId);
        previousOwnerSnap = await tx.get(previousOwnerRef);
      }

      final now = DateTime.now();

      if (provinceSnap.exists) {
        tx.update(provinceRef, {'ownerId': uid});
      } else {
        tx.set(provinceRef, {
          'ownerId': uid,
          'troops': 0,
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
            mines: _mineCount(newOwnerSnap) + mineDelta,
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
            mines: _mineCount(previousOwnerSnap) - mineDelta,
            now: now,
          ),
        );
      }
    });
  }

  /// Builds [building] on a province the player owns: pays the price,
  /// puts the building on the province, and (for a gold mine) raises the
  /// player's income. Throws [GameActionException] if it isn't allowed.
  ///
  /// NOTE: like [claimProvince], this runs on the client for now. It
  /// should move into a Cloud Function before real players use it.
  Future<void> constructBuilding({
    required String gameId,
    required String provinceId,
    required String uid,
    required BuildingDef building,
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
      if (_buildingTypeOf(data) != 'none') {
        return 'This province already has a building.';
      }

      final now = DateTime.now();
      final gold = PlayerState.fromDoc(playerSnap).goldAt(now);
      if (gold < building.cost) return 'Not enough gold.';

      final addsMine = building.id == GameRules.goldMine.id;

      tx.update(provinceRef, {
        'building': {'type': building.id, 'level': 1},
      });
      tx.update(
        playerRef,
        _settledIncomeUpdate(
          playerSnap,
          owned: _ownedCount(playerSnap),
          mines: _mineCount(playerSnap) + (addsMine ? 1 : 0),
          now: now,
          spend: building.cost.toDouble(),
        ),
      );
      return null;
    });

    if (error != null) throw GameActionException(error);
  }

  /// Removes the building from a province the player owns. No refund. If it
  /// was a gold mine, the player's income drops accordingly (gold earned so
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

      final removesMine = _hasGoldMine(data);

      tx.update(provinceRef, {
        'building': {'type': 'none', 'level': 0},
      });
      tx.update(
        playerRef,
        _settledIncomeUpdate(
          playerSnap,
          owned: _ownedCount(playerSnap),
          mines: _mineCount(playerSnap) - (removesMine ? 1 : 0),
          now: DateTime.now(),
        ),
      );
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

      final now = DateTime.now();
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

  // ---------------------------------------------------------------------
  // Join / reconcile
  // ---------------------------------------------------------------------

  /// Recounts the player's provinces and mines and fixes ownedCount /
  /// mineCount / goldRate if they have drifted (or were created under an
  /// older income rule, or the numbers in [GameRules] changed).
  /// Runs on every launch, so stored income always matches ownership.
  Future<void> _reconcileTerritoryIncome({
    required String gameId,
    required String uid,
  }) async {
    final ref = _playerRef(gameId, uid);
    final snap = await ref.get();
    final data = snap.data();
    if (data == null) return;

    final mine = _provincesRef(gameId).where('ownerId', isEqualTo: uid);
    final counts = await Future.wait([
      mine.count().get(),
      mine
          .where('building.type', isEqualTo: GameRules.goldMine.id)
          .count()
          .get(),
    ]);
    final owned = counts[0].count ?? 0;
    final mines = counts[1].count ?? 0;

    final storedCount = (data['ownedCount'] as num?)?.toInt();
    final storedMines = (data['mineCount'] as num?)?.toInt();
    final storedRate = (data['goldRate'] as num?)?.toDouble();
    final expectedRate =
        GameRules.incomeRate(territories: owned, goldMines: mines);
    final inSync = storedCount == owned &&
        storedMines == mines &&
        storedRate != null &&
        (storedRate - expectedRate).abs() < 1e-9;
    if (inSync) return;

    await ref.update(
      _settledIncomeUpdate(snap, owned: owned, mines: mines, now: DateTime.now()),
    );
    debugPrint('Income reconciled: $owned territories, $mines gold mines');
  }

  /// Makes sure the game and this player's document exist. Safe to call on
  /// every launch: existing documents are left untouched, so a returning
  /// player keeps their color and (later) their gold.
  Future<void> ensureJoined({
    required String gameId,
    required String uid,
  }) async {
    final gameRef = _gameRef(gameId);
    final gameSnap = await gameRef.get();
    if (!gameSnap.exists) {
      await gameRef.set({
        'name': 'Conquera World',
        'status': 'active',
        'createdAt': FieldValue.serverTimestamp(),
        'config': {
          'troopRegenPerSec': 0.1,
          'goldPerTerritoryPerSec': GameRules.goldPerTerritoryPerSec,
        },
      });
      debugPrint('Created game "$gameId"');
    }

    final playerRef = _playerRef(gameId, uid);
    final playerSnap = await playerRef.get();
    if (!playerSnap.exists) {
      final color = _playerColors[uid.hashCode.abs() % _playerColors.length];
      await playerRef.set({
        'displayName': 'Player',
        'colorHex': color,
        'joinedAt': FieldValue.serverTimestamp(),
        // Idle-style resource: a snapshot plus the time it was taken.
        'gold': 0,
        'ownedCount': 0,
        'mineCount': 0,
        'goldRate': 0.0, // grows with territories and gold mines
        'goldUpdatedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('Created player doc for $uid');
    }

    await _reconcileTerritoryIncome(gameId: gameId, uid: uid);
  }
}