import 'package:flutter/material.dart';

import 'building_overrides.dart';
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

  /// Only territories that a rule in building_overrides.dart explicitly
  /// allows (oil fields, diamond mines).
  producer,
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

  /// Extra gold per second for every bordering territory the owner also
  /// holds (a market trades only with its owner's own neighbors). Sea links
  /// count as borders.
  final double goldPerPartnerPerSec;

  /// Where this building is allowed.
  final BuildSite site;

  /// Extra defence: 0.5 makes the province 50% harder to invade.
  final double defenseBonus;

  /// The province sends its power to attacks launched by bordering
  /// provinces of the same owner (a barracks).
  final bool supportsAttacks;

  /// Short description shown in the province window. Null = the gold text.
  final String? effect;

  /// The owner can see the buildings and power of every territory that
  /// borders this one (a watchtower). Sea links count as borders.
  final bool revealsNeighbors;

  /// The province can't send troops to attacks or claims (a wall).
  final bool blocksAttacks;

  /// The owner sees the buildings and power of every territory whose icon
  /// lies inside this radius around the building's icon (a radar). Given as
  /// a fraction of the map width; 0 = none.
  final double revealRadius;

  /// How far this building can fire missiles, as a fraction of the map
  /// width (a missile silo); 0 = it can't.
  final double missileRadius;

  /// Icon of the USE button shown beside Manage. Null = no use button.
  final IconData? useIcon;

  /// Longer explanation shown in the building's info box.
  final String details;

  const BuildingDef({
    required this.id,
    required this.name,
    required this.icon,
    required this.cost,
    this.goldPerSec = 0,
    this.goldPerPartnerPerSec = 0,
    this.site = BuildSite.anywhere,
    this.defenseBonus = 0,
    this.supportsAttacks = false,
    this.effect,
    this.revealsNeighbors = false,
    this.blocksAttacks = false,
    this.revealRadius = 0,
    this.missileRadius = 0,
    this.useIcon,
    this.details = '',
  });

  /// True if what this building earns depends on how many bordering
  /// territories the owner holds (a market).
  bool get tradesWithNeighbors => goldPerPartnerPerSec > 0;

  /// Gold per second this building makes when it trades with [partners]
  /// bordering territories of its owner.
  /// [provinceId] applies that territory's rate from building_overrides.dart.
  double incomeFor(int partners, [String? provinceId]) =>
      (goldPerSec + goldPerPartnerPerSec * (partners < 0 ? 0 : partners)) *
      BuildingOverrides.rateOf(id, provinceId);

  /// Gold/sec gained per trading neighbor in [provinceId].
  double partnerRateFor(String? provinceId) =>
      goldPerPartnerPerSec * BuildingOverrides.rateOf(id, provinceId);

  /// Description for a province whose owner holds [partners] of its
  /// bordering territories.
  String effectLabelFor(int partners, [String? provinceId]) {
    if (effect != null) return effect!;
    final rate = BuildingOverrides.rateOf(id, provinceId);
    if (tradesWithNeighbors) {
      if (partners <= 0) {
        return '+${_trim(goldPerPartnerPerSec * rate * 60)} gold/min per neighbor';
      }
      return '+${_trim(incomeFor(partners, provinceId) * 60)} gold/min';
    }
    return '+${_trim(goldPerSec * rate * 60)} gold/min';
  }
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

  // ECONOMY (gold per second in code; the top bar shows /min or /hr)
  //
  //   tax      0.0005 /s =  1.8 /hr per territory
  //   mine     0.0010 /s =  3.6 /hr   cost 16  -> pays back in ~4.4 h
  //   harbor   0.0015 /s =  5.4 /hr   cost 24  -> ~4.4 h
  //   rig      0.0025 /s =  9.0 /hr   cost 40  -> ~4.4 h
  //   diamond  0.0040 /s = 14.4 /hr   cost 64  -> ~4.4 h
  //   uranium  0.0035 /s = 12.6 /hr   cost 56  -> ~4.4 h
  //   silver   0.0020 /s =  7.2 /hr   cost 32  -> ~4.4 h
  //   market   0.0003 /s =  1.08 /hr per bordering territory you own,
  //            cost 20 -> ~4.6 h with 4 partners (slower with fewer)
  //
  // Every income building pays itself back in about the same time, so
  // building early always snowballs; the better buildings just earn more
  // per slot (and need the right territory). A new territory costs the
  // claim price plus a squad or two to make its neighbors able to claim,
  // and pays back through tax and its building slot over many hours.
  // Units are untouched: a squad is 10 gold, so one mine is 1.6 squads.

  /// Gold price of claiming a bordering unclaimed province. Claiming does
  /// not start (or wait for) the attack cooldown.
  static const int claimCost = 25;

  /// Gold a player starts with when joining a world: enough for a squad, a
  /// first claim, and a mine or two.
  static const int startingGold = 100;

  /// Power a new player's starting territory begins with.
  static const double startingTroops = 10;

  /// How long a player must wait between attacks (win or lose).
  static const Duration attackCooldown = Duration(hours: 1);

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

  /// True if a province with [troops] power and [buildingType] may fight:
  /// it has enough power and doesn't hold a wall.
  static bool canFight(double troops, String buildingType) =>
      canAct(troops) && !(buildingById(buildingType)?.blocksAttacks ?? false);

  /// Taxes: every territory a player owns earns this much gold per second.
  static const double goldPerTerritoryPerSec = 0.0005;

  static const BuildingDef goldMine = BuildingDef(
    id: 'gold_mine',
    name: 'Gold mine',
    icon: Icons.factory,
    cost: 16,
    goldPerSec: 0.001,
    details: 'Produces gold for you around the clock. Can be built in any '
        'territory; gold-rich territories pay more.',
  );

  /// Coastal territories only.
  static const BuildingDef fishingHarbor = BuildingDef(
    id: 'fishing_harbor',
    name: 'Fishing harbor',
    icon: Icons.anchor,
    cost: 24,
    goldPerSec: 0.0015,
    site: BuildSite.coastal,
    details: 'Fishing income for territories with a coast. Landlocked '
        'territories cannot build it. Territories with bigger fish catches '
        'pay more.',
  );

  /// Island archipelagos only.
  static const BuildingDef offshoreRig = BuildingDef(
    id: 'offshore_rig',
    name: 'Offshore rig',
    icon: Icons.oil_barrel,
    cost: 40,
    goldPerSec: 0.0025,
    site: BuildSite.archipelago,
    details: 'The best gold income, but only island territories can build '
        'it. Islands with more oil pay more.',
  );

  /// Mainland oil producers only.
  static const BuildingDef oilField = BuildingDef(
    id: 'oil_field',
    name: 'Oil field',
    icon: Icons.local_gas_station,
    cost: 40,
    goldPerSec: 0.0025,
    site: BuildSite.producer,
    details: 'Same income as an offshore rig, built on the mainland. Only '
        'oil-producing territories can build it, and richer oil pays more.',
  );

  /// Diamond-producing territories only.
  static const BuildingDef diamondMine = BuildingDef(
    id: 'diamond_mine',
    name: 'Diamond mine',
    icon: Icons.diamond,
    cost: 64,
    goldPerSec: 0.004,
    site: BuildSite.producer,
    details: 'The richest single income. Only territories that really mine '
        'diamonds can build it, and bigger diamond output pays more.',
  );

  /// Uranium-producing territories only.
  static const BuildingDef uraniumMine = BuildingDef(
    id: 'uranium_mine',
    name: 'Uranium mine',
    icon: Icons.bolt,
    cost: 56,
    goldPerSec: 0.0035,
    site: BuildSite.producer,
    details: 'High income from nuclear fuel. Only territories that really '
        'mine uranium can build it, and bigger output pays more.',
  );

  /// Silver-producing territories only.
  static const BuildingDef silverMine = BuildingDef(
    id: 'silver_mine',
    name: 'Silver mine',
    icon: Icons.toll,
    cost: 32,
    goldPerSec: 0.002,
    site: BuildSite.producer,
    details: 'Steady income from silver. Only territories that really mine '
        'silver can build it, and bigger output pays more.',
  );

  /// Earns for every bordering territory its owner holds.
  static const BuildingDef market = BuildingDef(
    id: 'market',
    name: 'Market',
    icon: Icons.storefront,
    cost: 20,
    goldPerPartnerPerSec: 0.0003,
    details: 'Earns gold for every bordering territory you own (sea links '
        'count). Needs at least one neighbor.',
  );

  static const BuildingDef fortress = BuildingDef(
    id: 'fortress',
    name: 'Fortress',
    icon: Icons.fort,
    cost: 35,
    defenseBonus: 0.5,
    effect: '+50% defense',
    details: 'Makes this territory 50% harder to invade.',
  );

  /// Triples the power of the province when it is invaded (+200%).
  static const BuildingDef wall = BuildingDef(
    id: 'wall',
    name: 'Wall',
    icon: Icons.security,
    cost: 90,
    defenseBonus: 2.0,
    blocksAttacks: true,
    effect: '3x defense, no attacking',
    details: 'Triples this territory\'s power when invaded. The territory '
        'can no longer send troops to attacks or claims.',
  );

  /// Lifts the fog of war over every bordering territory.
  static const BuildingDef watchtower = BuildingDef(
    id: 'watchtower',
    name: 'Watchtower',
    icon: Icons.cell_tower,
    cost: 55,
    revealsNeighbors: true,
    effect: 'Reveals neighbors',
    details: 'Shows the buildings and power of every bordering territory '
        '(sea links count).',
  );

  /// Lifts the fog of war inside a circle around its icon.
  static const BuildingDef radar = BuildingDef(
    id: 'radar',
    name: 'Radar',
    icon: Icons.satellite_alt,
    cost: 90,
    revealRadius: 0.06,
    effect: 'Reveals nearby area',
    details: 'Shows the buildings and power of every territory inside its '
        'range. Select the radar on the map to see the range.',
  );

  static const BuildingDef barracks = BuildingDef(
    id: 'barracks',
    name: 'Barracks',
    icon: Icons.military_tech,
    cost: 30,
    supportsAttacks: true,
    effect: 'Backs neighbor attacks',
    details: 'Adds this territory\'s power to attacks launched by bordering '
        'territories you own.',
  );

  /// Fires missiles at enemy territories inside its range.
  static const BuildingDef missileSilo = BuildingDef(
    id: 'missile_silo',
    name: 'Missile silo',
    icon: Icons.rocket_launch,
    cost: 160,
    missileRadius: 0.09,
    useIcon: Icons.gps_fixed,
    effect: 'Fires missiles in range',
    details: 'Fires a missile at an enemy territory inside its range for 100 '
        'gold (1 hour cooldown per silo). A hit destroys the building there '
        'and removes 20 power. Select the silo on the map to see the range.',
  );

  /// Gold a missile launch costs.
  static const int missileCost = 100;

  /// How long a silo must reload between launches.
  static const Duration missileCooldown = Duration(hours: 1);

  /// Power a missile hit removes from the target territory.
  static const double missilePowerDamage = 20;

  static const List<BuildingDef> buildings = [
    goldMine,
    market,
    fishingHarbor,
    offshoreRig,
    oilField,
    diamondMine,
    uraniumMine,
    silverMine,
    fortress,
    wall,
    watchtower,
    radar,
    barracks,
    missileSilo,
  ];

  /// True if [building] may be built in the province [provinceId], which
  /// has [neighbors] bordering countries. A market needs at least one
  /// neighbor to ever trade with.
  static bool canBuildHere(
    BuildingDef building,
    String provinceId, {
    required int neighbors,
  }) {
    final forced = BuildingOverrides.allowedOf(building.id, provinceId);
    if (forced == false) return false;
    if (forced != true) {
      switch (building.site) {
        case BuildSite.anywhere:
          break;
        case BuildSite.coastal:
          if (!TerritoryTypes.isCoastal(provinceId)) return false;
        case BuildSite.archipelago:
          if (!TerritoryTypes.isIslandArchipelago(provinceId)) return false;
        case BuildSite.producer:
          return false; // only a rule with allowed: true opens it
      }
    }
    if (building.tradesWithNeighbors && neighbors <= 0) return false;
    return true;
  }

  /// The buildings the province may build (what the dropdown lists).
  static List<BuildingDef> buildingsFor(
    String provinceId, {
    required int neighbors,
  }) =>
      [
        for (final b in buildings)
          if (canBuildHere(b, provinceId, neighbors: neighbors)) b,
      ];

  /// After destroying a building, a player must wait this long before
  /// building anything again.
  static const Duration buildCooldownAfterDestroy = Duration(minutes: 5);

  /// How much stronger a province is when invaded: 1.5 with a fortress,
  /// 3.0 with a wall, 1.0 otherwise.
  static double defenseMultiplier(String buildingType) =>
      1 + (buildingById(buildingType)?.defenseBonus ?? 0);

  /// True for a building (watchtower) that reveals bordering territories.
  static bool revealsNeighbors(String buildingType) =>
      buildingById(buildingType)?.revealsNeighbors ?? false;

  /// Reveal radius of a building as a fraction of the map width (0 = none).
  static double revealRadiusOf(String buildingType) =>
      buildingById(buildingType)?.revealRadius ?? 0;

  /// Missile range of a building as a fraction of the map width (0 = none).
  static double missileRadiusOf(String buildingType) =>
      buildingById(buildingType)?.missileRadius ?? 0;

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