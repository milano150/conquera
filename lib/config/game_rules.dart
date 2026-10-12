import 'package:flutter/material.dart';

import 'territory_types.dart';

/// Shows up to 3 decimals without trailing zeros (0.06, 0.15, 12).
String _trim(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

/// Where a building may be built.
enum BuildSite {
  /// Any territory.
  anywhere,

  /// Any territory that is not landlocked.
  coastal,

  /// Island archipelagos only.
  archipelago,
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

  /// Extra gold per second for every country bordering the province (a
  /// market). Sea links count as borders.
  final double goldPerBorderPerSec;

  /// Where this building is allowed.
  final BuildSite site;

  /// Extra defence: 0.5 makes the province 50% harder to invade.
  final double defenseBonus;

  /// The province sends its power to attacks launched by bordering
  /// provinces of the same owner (a barracks).
  final bool supportsAttacks;

  /// Short description shown in the province window. Null = the gold text.
  final String? effect;

  const BuildingDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.cost,
    this.goldPerSec = 0,
    this.goldPerBorderPerSec = 0,
    this.site = BuildSite.anywhere,
    this.defenseBonus = 0,
    this.supportsAttacks = false,
    this.effect,
  });

  /// True if what this building earns depends on the bordering countries.
  bool get scalesWithBorders => goldPerBorderPerSec > 0;

  /// Gold per second this building makes in a province with [borders]
  /// bordering countries.
  double incomeFor(int borders) =>
      goldPerSec + goldPerBorderPerSec * (borders < 0 ? 0 : borders);

  /// Text for a province with [borders] bordering countries.
  String effectLabelFor(int borders) {
    if (effect != null) return effect!;
    final perMin = _trim(incomeFor(borders) * 60);
    if (scalesWithBorders) {
      final word = borders == 1 ? 'country' : 'countries';
      return 'trades with $borders bordering $word: +$perMin gold/min';
    }
    return 'increases gold production by +$perMin gold/min';
  }

  /// Text without a province (no border count known).
  String get effectLabel =>
      effect ??
      (scalesWithBorders
          ? '+${_trim(goldPerBorderPerSec * 60)} gold/min per bordering country'
          : 'increases gold production by +${_trim(goldPerSec * 60)} gold/min');
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

  /// Gold price of claiming a bordering unclaimed province. Claiming counts
  /// as an attack, so it starts the attack cooldown too.
  static const int claimCost = 100;

  /// Gold a player starts with when joining a world.
  static const int startingGold = 300;

  /// How long a player must wait between attacks (win or lose).
  static const Duration attackCooldown = Duration(seconds: 2);

  /// Share of the troops each fighting province loses when an attack
  /// fails (the defence loses the same total amount).
  static const double failedAttackLossShare = 0.75;

  /// A province must hold at least this much power to attack or claim. One
  /// power is the garrison that always stays behind, so a province with only
  /// 1 power can neither attack, nor support an attack, nor claim.
  static const double minPowerToAct = 2;

  /// True if a province with [troops] power may take part in an attack or a
  /// claim. Matches the whole numbers shown on the map (1.9 shows as 1).
  static bool canAct(double troops) => troops >= minPowerToAct;

  /// Taxes: every territory a player owns earns this much gold per second.
  static const double goldPerTerritoryPerSec = 0.0005;

  // -- Income buildings. Mine = 0.001/s; harbor a bit more; rig more still.

  static const BuildingDef goldMine = BuildingDef(
    id: 'gold_mine',
    name: 'Gold mine',
    icon: Icons.factory,
    cost: 30,
    goldPerSec: 0.001,
  );

  /// Coastal territories only.
  static const BuildingDef fishingHarbor = BuildingDef(
    id: 'fishing_harbor',
    name: 'Fishing harbor',
    icon: Icons.anchor,
    cost: 45,
    goldPerSec: 0.0015,
    site: BuildSite.coastal,
  );

  /// Island archipelagos only.
  static const BuildingDef offshoreRig = BuildingDef(
    id: 'offshore_rig',
    name: 'Offshore rig',
    icon: Icons.oil_barrel,
    cost: 75,
    goldPerSec: 0.0025,
    site: BuildSite.archipelago,
  );

  /// Earns more the more countries border the province.
  static const BuildingDef market = BuildingDef(
    id: 'market',
    name: 'Market',
    icon: Icons.storefront,
    cost: 40,
    goldPerBorderPerSec: 0.0003,
  );

  static const BuildingDef fortress = BuildingDef(
    id: 'fortress',
    name: 'Fortress',
    icon: Icons.fort,
    cost: 60,
    defenseBonus: 0.5,
    effect: 'makes this province 50% harder to invade',
  );

  static const BuildingDef barracks = BuildingDef(
    id: 'barracks',
    name: 'Barracks',
    icon: Icons.military_tech,
    cost: 50,
    supportsAttacks: true,
    effect: 'sends its power to attacks by bordering provinces',
  );

  static const List<BuildingDef> buildings = [
    goldMine,
    market,
    fishingHarbor,
    offshoreRig,
    fortress,
    barracks,
  ];

  /// True if [building] may be built in the province [provinceId], which
  /// has [borders] bordering countries. A market needs at least one
  /// neighbor to trade with.
  static bool canBuildHere(
    BuildingDef building,
    String provinceId, {
    required int borders,
  }) {
    switch (building.site) {
      case BuildSite.anywhere:
        break;
      case BuildSite.coastal:
        if (!TerritoryTypes.isCoastal(provinceId)) return false;
      case BuildSite.archipelago:
        if (!TerritoryTypes.isIslandArchipelago(provinceId)) return false;
    }
    if (building.scalesWithBorders && borders <= 0) return false;
    return true;
  }

  /// The buildings the province may build (what the dropdown lists).
  static List<BuildingDef> buildingsFor(
    String provinceId, {
    required int borders,
  }) =>
      [
        for (final b in buildings)
          if (canBuildHere(b, provinceId, borders: borders)) b,
      ];

  /// After destroying a building, a player must wait this long before
  /// building anything again.
  static const Duration buildCooldownAfterDestroy = Duration(minutes: 1);

  /// How much stronger a province is when invaded: 1.5 with a fortress,
  /// 1.0 otherwise.
  static double defenseMultiplier(String buildingType) =>
      1 + (buildingById(buildingType)?.defenseBonus ?? 0);

  /// True for a building (barracks) that joins bordering provinces' attacks.
  static bool supportsAttacks(String buildingType) =>
      buildingById(buildingType)?.supportsAttacks ?? false;

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

  /// Gold per second for a player with this many territories, plus the
  /// combined output of all their buildings ([buildingIncome], per second).
  static double incomeRate({
    required int territories,
    required double buildingIncome,
  }) {
    return territories * goldPerTerritoryPerSec + buildingIncome;
  }
}