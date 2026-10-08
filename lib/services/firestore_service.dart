import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';

/// All Firestore access for Conquera lives here, so the rest of the app
/// never builds collection paths by hand.
///
/// Layout (see the DB structure we agreed on):
///   games/{gameId}
///   games/{gameId}/players/{uid}
///   games/{gameId}/provinces/{provinceId}   <- added in a later step
class FirestoreService {
  FirestoreService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// One shared world for now.
  static const String defaultGameId = 'main';

  /// Taxes: every territory a player owns earns this much gold per second.
  /// There is no flat base income.
  static const double goldPerTerritoryPerSec = 0.01;

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

  /// Live updates of one player's document (null if it doesn't exist yet).
  Stream<PlayerState?> watchPlayer({
    required String gameId,
    required String uid,
  }) {
    return _playerRef(gameId, uid).snapshots().map(
          (snap) => snap.exists ? PlayerState.fromDoc(snap) : null,
        );
  }

  CollectionReference<Map<String, dynamic>> _provincesRef(String gameId) =>
      _gameRef(gameId).collection('provinces');

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

  /// DEBUG ONLY: makes [uid] the owner of [provinceId], no questions asked.
  /// Real claiming will go through a Cloud Function that checks gold,
  /// adjacency, and so on.
  ///
  /// Ownership changes the income rate, so each affected player's gold is
  /// settled first (gold = gold now, timestamp = now) and only then given
  /// the new rate. All of it happens in one transaction.
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
      final previousOwnerId = provinceSnap.data()?['ownerId'] as String?;
      if (previousOwnerId == uid) return; // already yours

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
            now: now,
          ),
        );
      }
    });
  }

  int _ownedCount(DocumentSnapshot<Map<String, dynamic>> playerSnap) =>
      (playerSnap.data()?['ownedCount'] as num?)?.toInt() ?? 0;

  /// The fields to write when a player's territory count changes: gold is
  /// settled up to [now] at the OLD rate, then the new count and the rate
  /// derived from it are stored. Without settling, changing the rate would
  /// retroactively change gold already earned.
  Map<String, dynamic> _settledIncomeUpdate(
    DocumentSnapshot<Map<String, dynamic>> playerSnap, {
    required int owned,
    required DateTime now,
  }) {
    final count = owned < 0 ? 0 : owned;
    return {
      'gold': PlayerState.fromDoc(playerSnap).goldAt(now),
      'goldUpdatedAt': FieldValue.serverTimestamp(),
      'ownedCount': count,
      'goldRate': count * goldPerTerritoryPerSec,
    };
  }

  /// Recounts the player's provinces and fixes ownedCount / goldRate if
  /// they have drifted (or were created under an older income rule).
  /// Runs on every launch, so stored income always matches ownership.
  Future<void> _reconcileTerritoryIncome({
    required String gameId,
    required String uid,
  }) async {
    final ref = _playerRef(gameId, uid);
    final snap = await ref.get();
    final data = snap.data();
    if (data == null) return;

    final countResult = await _provincesRef(gameId)
        .where('ownerId', isEqualTo: uid)
        .count()
        .get();
    final owned = countResult.count ?? 0;

    final storedCount = (data['ownedCount'] as num?)?.toInt();
    final storedRate = (data['goldRate'] as num?)?.toDouble();
    final expectedRate = owned * goldPerTerritoryPerSec;
    final inSync = storedCount == owned &&
        storedRate != null &&
        (storedRate - expectedRate).abs() < 1e-9;
    if (inSync) return;

    await ref.update(
      _settledIncomeUpdate(snap, owned: owned, now: DateTime.now()),
    );
    debugPrint('Territory income reconciled: $owned territories');
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
          'goldPerTerritoryPerSec': 0.01,
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
        'goldRate': 0.0, // grows with territories: see goldPerTerritoryPerSec
        'goldUpdatedAt': FieldValue.serverTimestamp(),
      });
      debugPrint('Created player doc for $uid');
    }

    await _reconcileTerritoryIncome(gameId: gameId, uid: uid);
  }
}