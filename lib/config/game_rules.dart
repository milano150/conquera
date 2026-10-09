import 'package:flutter/material.dart';

String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// A building a province can hold (one per province for now).
class BuildingDef {
  final String id;
  final String name;
  final IconData icon;

  /// One-off price in gold.
  final int cost;

  /// Extra gold per second for the owner.
  final double goldPerSec;

  const BuildingDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.cost,
    required this.goldPerSec,
  });

  String get effectLabel =>
      'increases gold production by +${_trim(goldPerSec * 60)} gold/min';
}

/// An army unit that can be bought to raise a province's power.
class UnitDef {
  final String id;
  final String name;
  final int power;
  final int cost;

  const UnitDef({
    required this.id,
    required this.name,
    required this.power,
    required this.cost,
  });
}

/// Every tunable number of the game in one place.
///
/// Unit prices get cheaper per point of power as units get bigger:
///   squad     10 gold for  +5  (2.0 per power)
///   legion    18 gold for +10  (1.8 per power)
///   battalion 32 gold for +20  (1.6 per power)
/// so a battalion (32) costs less than 4 squads (40) for the same +20.
class GameRules {
  const GameRules._();

  /// How long a player must wait between attacks (win or lose).
  static const Duration attackCooldown = Duration(minutes: 1);

  /// The luck margin of a battle: each side's power is multiplied by a
  /// random number between (1 - attackLuck) and (1 + attackLuck).
  static const double attackLuck = 0.30;

  /// Taxes: every territory a player owns earns this much gold per second.
  static const double goldPerTerritoryPerSec = 0.01;

  static const BuildingDef goldMine = BuildingDef(
    id: 'gold_mine',
    name: 'Gold mine',
    icon: Icons.factory,
    cost: 30,
    goldPerSec: 0.02,
  );

  static const List<BuildingDef> buildings = [goldMine];

  static const List<UnitDef> units = [
    UnitDef(id: 'squad', name: 'Squad', power: 5, cost: 10),
    UnitDef(id: 'legion', name: 'Legion', power: 10, cost: 18),
    UnitDef(id: 'battalion', name: 'Battalion', power: 20, cost: 32),
  ];

  static BuildingDef? buildingById(String id) {
    for (final b in buildings) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Gold per second for a player with this many territories and mines.
  static double incomeRate({required int territories, required int goldMines}) {
    return territories * goldPerTerritoryPerSec +
        goldMines * goldMine.goldPerSec;
  }
}