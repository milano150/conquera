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

  /// Mountainous territories only (see TerritoryTypes.mountainous).
  mountainous,

  /// Only territories that a rule in building_overrides.dart explicitly
  /// allows (oil fields, diamond mines).
  producer,
}

/// A building a province can hold (one per province for now).
class BuildingDef {
  final String id;
  final String name;
  final IconData icon;

  /// Default one-off price in gold (a world can override it, see [cost]).
  final int baseCost;

  /// One-off price in gold in the open world: the world's own price from the
  /// admin page if it set one, else [baseCost].
  int get cost => GameRules.buildingCostOf(id, baseCost);

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

  /// How far this building's navy can attack, as a fraction of the map
  /// width (a naval base); 0 = it has no navy.
  final double navalRadius;

  /// Ids of buildings this one needs on a bordering territory of the same
  /// owner (an oil refinery needs a rig). Its income is 0 while none of them
  /// is there. Empty = no such need.
  final Set<String> suppliedBy;

  /// One-shot trap (mines): when the territory is attacked, every troop that
  /// took part is wiped out, the attack fails and the building is used up.
  final bool isTrap;

  /// Invisible to radars and watchtowers: only the owner sees it.
  final bool hiddenFromScouting;

  /// Shields this territory and every bordering one (same owner) from
  /// missiles (a dome).
  final bool missileShield;

  /// Icon of the USE button shown beside Manage. Null = no use button.
  final IconData? useIcon;

  /// Ids of buildings this one must be placed next to (a bordering
  /// territory of the same owner), e.g. a shipyard needs a naval base.
  /// Unlike [suppliedBy] it only limits where it can be built. Empty = none.
  final Set<String> requiresNeighbor;

  /// Longer explanation shown in the building's info box.
  final String details;

  const BuildingDef({
    required this.id,
    required this.name,
    required this.icon,
    required int cost,
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
    this.navalRadius = 0,
    this.suppliedBy = const {},
    this.isTrap = false,
    this.hiddenFromScouting = false,
    this.missileShield = false,
    this.useIcon,
    this.requiresNeighbor = const {},
    this.details = '',
  }) : baseCost = cost;

  /// True if what this building earns depends on how many bordering
  /// territories the owner holds (a market).
  bool get tradesWithNeighbors =>
      goldPerPartnerPerSec > 0 || suppliedBy.isNotEmpty;

  /// True if a bordering building of type [neighborType] counts as one of
  /// this building's partners (a market counts every neighbor, a refinery
  /// only its suppliers).
  bool countsAsPartner(String neighborType) =>
      suppliedBy.isEmpty || suppliedBy.contains(neighborType);

  /// Gold per second this building makes when it trades with [partners]
  /// bordering territories of its owner.
  /// [provinceId] applies that territory's rate from building_overrides.dart.
  double incomeFor(int partners, [String? provinceId]) =>
      suppliedBy.isNotEmpty
          ? goldPerSec *
              (partners < 0 ? 0 : partners) *
              BuildingOverrides.rateOf(id, provinceId)
          : (goldPerSec +
                  goldPerPartnerPerSec * (partners < 0 ? 0 : partners)) *
              BuildingOverrides.rateOf(id, provinceId);

  /// Gold/sec gained per trading neighbor in [provinceId].
  double partnerRateFor(String? provinceId) =>
      goldPerPartnerPerSec * BuildingOverrides.rateOf(id, provinceId);

  /// Description for a province whose owner holds [partners] of its
  /// bordering territories.
  String effectLabelFor(int partners, [String? provinceId]) {
    if (effect != null) return effect!;
    final rate = BuildingOverrides.rateOf(id, provinceId);
    if (suppliedBy.isNotEmpty) {
      if (partners <= 0) return 'No supply: needs a bordering rig';
      return '+${_trim(incomeFor(partners, provinceId) * 60)} gold/min';
    }
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
///   squad     20 gold for  +5  (4.0 per power)
///   legion    36 gold for +10  (3.6 per power)
///   battalion 64 gold for +20  (3.2 per power)
/// so a battalion (64) costs less than 4 squads (80) for the same +20.
class GameRules {
  const GameRules._();

  // ECONOMY (gold per second in code; the top bar shows /min or /hr)
  //
  // Fast-and-chaotic balance: every income building pays itself back in
  // roughly 25-40 hours (before per-territory multipliers).
  //
  //   tax      0.00030 /s =  1.08 /hr per territory
  //   mine     0.00040 /s =  1.44 /hr   cost  35 -> ~24 h
  //   harbor   0.00060 /s =  2.16 /hr   cost  65 -> ~30 h
  //   rig/oil  0.00110 /s =  3.96 /hr   cost 115 -> ~29 h
  //   refinery 0.00090 /s =  3.24 /hr per supplier, cost 200 -> ~31 h (2)
  //   resort   0.00170 /s =  6.12 /hr   cost 250 -> ~41 h
  //   diamond  0.00160 /s =  5.76 /hr   cost 165 -> ~29 h
  //   uranium  0.00145 /s =  5.22 /hr   cost 150 -> ~29 h
  //   silver   0.00080 /s =  2.88 /hr   cost  85 -> ~30 h
  //   market   0.00008 /s =  0.29 /hr per bordering territory you own,
  //            cost 40 -> ~35 h with 4 partners
  //
  // Defence, scouting and missile buildings, units, navy, claims and
  // missiles still cost more than income buildings, so gold has to be
  // chosen, but war is affordable.

  // ---------------------------------------------------------------------
  // Per-world settings. The admin page writes them into the world document
  // (`config`, plus the older `attackCooldownMinutes`); the open screens call
  // [applyWorldConfig] on every change, so prices and cooldowns follow live,
  // even after the game has started. Anything a world doesn't set keeps the
  // default written next to it below.
  // ---------------------------------------------------------------------
  static Map<String, dynamic> _cfg = const {};
  static num? _legacyAttackMinutes;

  /// Reads the settings out of a world document's data (null = defaults).
  static void applyWorldConfig(Map<String, dynamic>? world) {
    final c = world?['config'];
    _cfg = c is Map ? Map<String, dynamic>.from(c) : const {};
    final legacy = world?['attackCooldownMinutes'];
    _legacyAttackMinutes = legacy is num && legacy >= 0 ? legacy : null;
  }

  /// Back to the defaults (when a world is closed).
  static void resetWorldConfig() => applyWorldConfig(null);

  static num _n(String key, num def) {
    final v = _cfg[key];
    return v is num && v >= 0 ? v : def;
  }

  /// A per-building value from the group [group] (null = not set).
  static num? _perBuilding(String group, String id) {
    final g = _cfg[group];
    final v = g is Map ? g[id] : null;
    return v is num && v >= 0 ? v : null;
  }

  /// A cooldown in minutes from `config.cooldowns`.
  static Duration _cooldown(String key, Duration def) {
    final g = _cfg['cooldowns'];
    final v = g is Map ? g[key] : null;
    if (v is! num || v < 0) return def;
    return Duration(milliseconds: (v * 60000).round());
  }

  /// The world's price for [id], or [base] when it sets none.
  static int buildingCostOf(String id, int base) =>
      _perBuilding('buildingCosts', id)?.round() ?? base;

  /// Gold price of claiming a bordering unclaimed province. Claiming does
  /// not start (or wait for) the attack cooldown.
  static int get claimCost => _n('claimCost', 15).round();

  /// Claim price grows with the territories you already own:
  /// claimCost + claimCostPerTerritory per extra territory, up to claimCostMax.
  static int get claimCostPerTerritory =>
      _n('claimCostPerTerritory', 3).round();
  static int get claimCostMax => _n('claimCostMax', 120).round();

  /// Gold per point of power when reinforcing (land / navy).
  static int get landGoldPerPower => _n('landGoldPerPower', 2).round();
  static int get navyGoldPerPower => _n('navyGoldPerPower', 4).round();

  /// What claiming costs a player who owns [owned] territories.
  static int claimCostFor(int owned) {
    final extra = (owned < 1 ? 0 : owned - 1) * claimCostPerTerritory;
    final c = claimCost + extra;
    return c > claimCostMax ? claimCostMax : c;
  }

  /// Each income building of a kind you already own makes the next one of
  /// the SAME kind pricier: +20% per one owned, up to x4. Silver mines only
  /// raise the price of silver mines. Defence, scouting and missile
  /// buildings keep a flat price.
  static double get buildCostStep => _n('buildCostStep', 0.15).toDouble();
  static double get buildCostMaxMultiplier =>
      _n('buildCostMaxMultiplier', 3.0).toDouble();

  /// True if [buildingType] earns gold (so its price escalates).
  static bool isIncomeBuilding(String buildingType) {
    final b = buildingById(buildingType);
    return b != null && (b.goldPerSec > 0 || b.goldPerPartnerPerSec > 0);
  }

  /// Price of the next [building] for a player who already owns [owned] of
  /// that same building.
  static int buildCostFor(BuildingDef building, int owned) {
    if (!(building.goldPerSec > 0 || building.goldPerPartnerPerSec > 0)) {
      return building.cost;
    }
    final n = owned < 0 ? 0 : owned;
    // A building can have its own upscale step / cap in the world's settings.
    final step =
        _perBuilding('buildingStep', building.id)?.toDouble() ?? buildCostStep;
    final cap = _perBuilding('buildingMaxMult', building.id)?.toDouble() ??
        buildCostMaxMultiplier;
    var mult = 1 + step * n;
    if (mult > cap) mult = cap;
    return (building.cost * mult).round();
  }

  /// Gold a player starts with when joining a world: enough for a squad, a
  /// first claim, and a mine or two.
  static int get startingGold => _n('startingGold', 250).round();

  /// How long an insurgent must hide in a territory before they can
  /// overthrow its owner.
  static Duration get overthrowDelay =>
      _cooldown('overthrow', const Duration(hours: 3));

  /// True for a building with no neighbor links, supply chain or navy: it
  /// can change hands or be built in secret without any other territory's
  /// income depending on it.
  static bool isPlainBuilding(String buildingType) {
    final def = buildingById(buildingType);
    if (def == null) return false;
    return !def.tradesWithNeighbors &&
        def.suppliedBy.isEmpty &&
        !suppliesOthers(buildingType) &&
        def.navalRadius <= 0;
  }

  /// Buildings an insurgent may build in their hideout: plain gold
  /// producers.
  static bool insurgentCanBuild(BuildingDef building) =>
      building.goldPerSec > 0 && isPlainBuilding(building.id);

  /// Power a new player's starting territory begins with.
  static const double startingTroops = 10;

  /// Attack cooldown used when a world doesn't set its own.
  static const Duration defaultAttackCooldown = Duration(minutes: 30);

  /// How long a player must wait between attacks (win or lose). Set per
  /// world from the admin page (field `attackCooldownMinutes` on the world
  /// document); the map screen keeps this up to date while a world is open.
  static Duration get attackCooldown => _cooldown(
        'attack',
        _legacyAttackMinutes == null
            ? defaultAttackCooldown
            : Duration(
                milliseconds: (_legacyAttackMinutes! * 60000).round()),
      );

  /// How long a trade offer stays open.
  static Duration get tradeOfferLifetime =>
      _cooldown('tradeOffer', const Duration(hours: 6));

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
  static const double goldPerTerritoryPerSec = 0.0003;

  static const BuildingDef goldMine = BuildingDef(
    id: 'gold_mine',
    name: 'Gold mine',
    icon: Icons.factory,
    cost: 35,
    goldPerSec: 0.0004,
    details: 'Produces gold for you around the clock. Can be built in any '
        'territory; gold-rich territories pay more.',
  );

  /// Coastal territories only.
  static const BuildingDef fishingHarbor = BuildingDef(
    id: 'fishing_harbor',
    name: 'Fishing harbor',
    icon: Icons.anchor,
    cost: 65,
    goldPerSec: 0.0006,
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
    cost: 115,
    goldPerSec: 0.0011,
    site: BuildSite.archipelago,
    details: 'The best gold income, but only island territories can build '
        'it. Islands with more oil pay more.',
  );

  /// Mainland oil producers only.
  static const BuildingDef oilField = BuildingDef(
    id: 'oil_field',
    name: 'Oil field',
    icon: Icons.local_gas_station,
    cost: 115,
    goldPerSec: 0.0011,
    site: BuildSite.producer,
    details: 'Same income as an offshore rig, built on the mainland. Only '
        'oil-producing territories can build it, and richer oil pays more.',
  );

  /// Needs a bordering oil rig or oil field of the same owner. Earns gold per
  /// bordering supplier, and nothing while none is there (never built, destroyed or captured).
  static const BuildingDef oilRefinery = BuildingDef(
    id: 'oil_refinery',
    name: 'Oil refinery',
    icon: Icons.propane_tank,
    cost: 200,
    goldPerSec: 0.0009, // per bordering rig or oil field
    suppliedBy: {'offshore_rig', 'oil_field'},
    details: 'Refines the oil of bordering offshore rigs and oil fields that '
        'you own, earning gold for each one. If every bordering rig is '
        'destroyed or lost, it earns nothing until one is built again.',
  );

  /// Island archipelagos only.
  static const BuildingDef islandResort = BuildingDef(
    id: 'island_resort',
    name: 'Island resort',
    icon: Icons.beach_access,
    cost: 250,
    goldPerSec: 0.0017,
    site: BuildSite.archipelago,
    details: 'A costly tourist resort with a high income. Only island '
        'territories can build it.',
  );

  /// Diamond-producing territories only.
  static const BuildingDef diamondMine = BuildingDef(
    id: 'diamond_mine',
    name: 'Diamond mine',
    icon: Icons.diamond,
    cost: 165,
    goldPerSec: 0.0016,
    site: BuildSite.producer,
    details: 'The richest single income. Only territories that really mine '
        'diamonds can build it, and bigger diamond output pays more.',
  );

  /// Uranium-producing territories only.
  static const BuildingDef uraniumMine = BuildingDef(
    id: 'uranium_mine',
    name: 'Uranium mine',
    icon: Icons.bolt,
    cost: 150,
    goldPerSec: 0.00145,
    site: BuildSite.producer,
    details: 'High income from nuclear fuel. Only territories that really '
        'mine uranium can build it, and bigger output pays more.',
  );

  /// Silver-producing territories only.
  static const BuildingDef silverMine = BuildingDef(
    id: 'silver_mine',
    name: 'Silver mine',
    icon: Icons.toll,
    cost: 85,
    goldPerSec: 0.0008,
    site: BuildSite.producer,
    details: 'Steady income from silver. Only territories that really mine '
        'silver can build it, and bigger output pays more.',
  );

  /// Earns for every bordering territory its owner holds.
  static const BuildingDef market = BuildingDef(
    id: 'market',
    name: 'Market',
    icon: Icons.storefront,
    cost: 40,
    goldPerPartnerPerSec: 0.00008,
    details: 'Earns gold for every bordering territory you own (sea links '
        'count). Needs at least one neighbor.',
  );

  static const BuildingDef fortress = BuildingDef(
    id: 'fortress',
    name: 'Fortress',
    icon: Icons.fort,
    cost: 80,
    defenseBonus: 0.5,
    effect: '+50% defense',
    details: 'Makes this territory 50% harder to invade.',
  );

  /// Triples the power of the province when it is invaded (+200%).
  static const BuildingDef wall = BuildingDef(
    id: 'wall',
    name: 'Wall',
    icon: Icons.security,
    cost: 190,
    defenseBonus: 2.0,
    blocksAttacks: true,
    effect: '3x defense, no attacking',
    details: 'Triples this territory\'s power when invaded. The territory '
        'can no longer send troops to attacks or claims.',
  );

  /// One-use trap: wipes out every troop of an attack on this territory.
  /// Radars and watchtowers can't see it.
  static const BuildingDef mines = BuildingDef(
    id: 'mines',
    name: 'Mines',
    icon: Icons.dangerous,
    cost: 90,
    isTrap: true,
    hiddenFromScouting: true,
    effect: 'One-use trap, hidden',
    details: 'A hidden trap. When an enemy attacks this territory, every troop '
        'that took part in the attack is killed, the attack fails and the '
        'mines are used up. Radars and watchtowers cannot see them.',
  );

  /// Blocks missiles aimed at this territory or any bordering one.
  static const BuildingDef dome = BuildingDef(
    id: 'dome',
    name: 'Dome',
    icon: Icons.wb_twighlight,
    cost: 290,
    missileShield: true,
    effect: 'Blocks missiles nearby',
    details: 'Protects this territory and every bordering territory you own '
        'from missile attacks. A missile that hits the shield is wasted.',
  );

  /// Lifts the fog of war over every bordering territory.
  static const BuildingDef watchtower = BuildingDef(
    id: 'watchtower',
    name: 'Watchtower',
    icon: Icons.cell_tower,
    cost: 90,
    revealsNeighbors: true,
    effect: 'Reveals neighbors',
    details: 'Shows the buildings and power of every bordering territory '
        '(sea links count).',
  );

  /// Lifts the fog of war inside a circle around its icon.
  static const BuildingDef radar = BuildingDef(
    id: 'radar',
    name: 'Radar',
    icon: Icons.settings_input_antenna,
    cost: 160,
    revealRadius: 0.06,
    effect: 'Reveals nearby area',
    details: 'Shows the buildings and power of every territory inside its '
        'range. Select the radar on the map to see the range.',
  );

  /// A radar with a much larger range; mountain territories only.
  static const BuildingDef highAltitudeRadar = BuildingDef(
    id: 'high_altitude_radar',
    name: 'High altitude radar',
    icon: Icons.wifi_tethering,
    cost: 320,
    site: BuildSite.mountainous,
    revealRadius: 0.12,
    effect: 'Reveals a wide area',
    details: 'A radar with double the range. Shows the buildings and power of '
        'every territory inside its range. Can only be built in mountainous '
        'territories. Select it on the map to see the range.',
  );

  static const BuildingDef barracks = BuildingDef(
    id: 'barracks',
    name: 'Barracks',
    icon: Icons.military_tech,
    cost: 65,
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
    cost: 350,
    missileRadius: 0.09,
    useIcon: Icons.gps_fixed,
    effect: 'Fires missiles in range',
    details: 'Fires a missile at an enemy territory inside its range for 150 '
        'gold (90 minute cooldown per silo). A hit destroys the building there '
        'and removes 20 power. Select the silo on the map to see the range.',
  );

  /// Fires the base's navy at coastal enemy territories inside its range.
  /// Navy is bought in the Reinforce window (it is much costlier than land
  /// power) and is shown in blue next to the power on the map.
  static const BuildingDef navalBase = BuildingDef(
    id: 'naval_base',
    name: 'Naval base',
    icon: Icons.directions_boat,
    cost: 300,
    site: BuildSite.coastal,
    navalRadius: 0.05,
    useIcon: Icons.sailing,
    effect: 'Navy attacks in range',
    details: 'Holds a navy (up to 200 power, bought in Reinforce) that can '
        'attack coastal enemy territories inside its range, even without a '
        'border, or claim unclaimed coastal territories there (costs gold and '
        '1 navy). Select the base and press the blue button. A naval attack '
        'starts the attack cooldown.',
  );

  /// Boosts a bordering naval base: +100 navy capacity and +25% naval range
  /// per shipyard, counting at most [maxShipyards] of them. Can only be
  /// built next to a naval base of the same owner.
  static const BuildingDef shipyard = BuildingDef(
    id: 'shipyard',
    name: 'Shipyard',
    icon: Icons.construction,
    cost: 200,
    site: BuildSite.coastal,
    requiresNeighbor: {'naval_base'},
    effect: 'Boosts a bordering naval base',
    details: 'Must be built next to one of your naval bases. Each shipyard '
        'next to a naval base adds 100 navy capacity and 25% naval range. '
        'Two shipyards give +200 capacity and +50% range. Only 2 count per '
        'naval base, more have no extra effect.',
  );

  /// Shipyards that count for one naval base.
  static const int maxShipyards = 2;

  /// Navy capacity added per shipyard.
  static const double navyPerShipyard = 100;

  /// Naval range added per shipyard, as a share of the base range.
  static const double rangePerShipyard = 0.25;

  /// Shipyards among [neighborTypes] (building types of the bordering
  /// territories the base's owner holds), capped at [maxShipyards].
  static int shipyardCount(Iterable<String> neighborTypes) =>
      neighborTypes.where((t) => t == 'shipyard').length > maxShipyards
          ? maxShipyards
          : neighborTypes.where((t) => t == 'shipyard').length;

  /// Navy a naval base holds with [shipyards] bordering shipyards.
  static double maxNavyFor(int shipyards) =>
      maxNavy + navyPerShipyard * shipyards.clamp(0, maxShipyards);

  /// Naval range (fraction of map width) of [buildingType] with [shipyards]
  /// bordering shipyards.
  static double navalRadiusWith(String buildingType, int shipyards) =>
      navalRadiusOf(buildingType) *
      (1 + rangePerShipyard * shipyards.clamp(0, maxShipyards));

  /// Blue used for everything naval.
  static const Color navyColor = Color(0xFF2E7BEA);

  /// Most navy power a single naval base can hold.
  static const double maxNavy = 200;

  /// Ships bought in the Reinforce window of a naval base. Much costlier per
  /// point of power than land units (2.0 / 1.8 / 1.6 gold per power).
  static const List<UnitDef> navyUnits = [
    UnitDef(id: 'patrol_boat', name: 'Patrol boat', power: 5, cost: 60),
    UnitDef(id: 'destroyer', name: 'Destroyer', power: 10, cost: 110),
    UnitDef(id: 'cruiser', name: 'Cruiser', power: 20, cost: 200),
  ];

  /// Boosts a bordering missile silo: +50% missile range and cheaper
  /// missiles. Only one counts per silo, more have no extra effect. Can only
  /// be built next to a missile silo of the same owner.
  static const BuildingDef missileArsenal = BuildingDef(
    id: 'missile_arsenal',
    name: 'Missile arsenal',
    icon: Icons.inventory_2,
    cost: 270,
    requiresNeighbor: {'missile_silo'},
    effect: 'Boosts a bordering missile silo',
    details: 'Must be built next to one of your missile silos. Adds 50% '
        'missile range and cuts the cost of each missile by 30% for that '
        'silo. Only 1 counts per silo, more have no extra effect.',
  );

  /// Arsenals that count for one missile silo.
  static const int maxArsenals = 1;

  /// Extra missile range per arsenal, as a share of the silo's range.
  static const double arsenalRangeBonus = 0.5;

  /// Share of the missile price an arsenal takes off.
  static const double arsenalCostDiscount = 0.3;

  /// Arsenals among [neighborTypes] (building types of the bordering
  /// territories the silo's owner holds), capped at [maxArsenals].
  static int arsenalCount(Iterable<String> neighborTypes) =>
      neighborTypes.where((t) => t == 'missile_arsenal').length > maxArsenals
          ? maxArsenals
          : neighborTypes.where((t) => t == 'missile_arsenal').length;

  /// Missile range (fraction of map width) of [buildingType] with
  /// [arsenals] bordering arsenals.
  static double missileRadiusWith(String buildingType, int arsenals) =>
      missileRadiusOf(buildingType) *
      (1 + arsenalRangeBonus * arsenals.clamp(0, maxArsenals));

  /// Gold one missile costs with [arsenals] bordering arsenals.
  static int missileCostWith(int arsenals) => (missileCost *
          (1 - arsenalCostDiscount * arsenals.clamp(0, maxArsenals)))
      .round();

  /// Gold a missile launch costs.
  static int get missileCost => _n('missileCost', 150).round();

  /// How long a silo must reload between launches.
  static Duration get missileCooldown =>
      _cooldown('missile', const Duration(minutes: 90));

  /// Power a missile hit removes from the target territory.
  static const double missilePowerDamage = 20;

  static const List<BuildingDef> buildings = [
    goldMine,
    market,
    fishingHarbor,
    offshoreRig,
    oilField,
    oilRefinery,
    islandResort,
    diamondMine,
    uraniumMine,
    silverMine,
    fortress,
    wall,
    mines,
    dome,
    watchtower,
    radar,
    highAltitudeRadar,
    barracks,
    missileSilo,
    navalBase,
    shipyard,
    missileArsenal,
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
        case BuildSite.mountainous:
          if (!TerritoryTypes.isMountainous(provinceId)) return false;
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
  static Duration get buildCooldownAfterDestroy =>
      _cooldown('buildAfterDestroy', const Duration(minutes: 3));

  /// How much stronger a province is when invaded: 1.5 with a fortress,
  /// 3.0 with a wall, 1.0 otherwise.
  static double defenseMultiplier(String buildingType) =>
      1 + (buildingById(buildingType)?.defenseBonus ?? 0);

  /// True for a trap building (mines).
  static bool isTrap(String buildingType) =>
      buildingById(buildingType)?.isTrap ?? false;

  /// True for a building that radars and watchtowers can't see (mines).
  static bool hiddenFromScouting(String buildingType) =>
      buildingById(buildingType)?.hiddenFromScouting ?? false;

  /// True for a building (dome) that shields its surroundings from missiles.
  static bool missileShield(String buildingType) =>
      buildingById(buildingType)?.missileShield ?? false;

  /// True for a building (watchtower) that reveals bordering territories.
  static bool revealsNeighbors(String buildingType) =>
      buildingById(buildingType)?.revealsNeighbors ?? false;

  /// Reveal radius of a building as a fraction of the map width (0 = none).
  static double revealRadiusOf(String buildingType) =>
      buildingById(buildingType)?.revealRadius ?? 0;

  /// Missile range of a building as a fraction of the map width (0 = none).
  static double missileRadiusOf(String buildingType) =>
      buildingById(buildingType)?.missileRadius ?? 0;

  /// True if some building (a refinery) needs [buildingType] next to it.
  static bool suppliesOthers(String buildingType) =>
      buildings.any((b) => b.suppliedBy.contains(buildingType));

  /// Naval range of a building as a fraction of the map width (0 = none).
  static double navalRadiusOf(String buildingType) =>
      buildingById(buildingType)?.navalRadius ?? 0;

  /// True for a building (barracks) that joins bordering provinces' attacks.
  static bool supportsAttacks(String buildingType) =>
      buildingById(buildingType)?.supportsAttacks ?? false;

  static const List<UnitDef> units = [
    UnitDef(id: 'squad', name: 'Squad', power: 5, cost: 20),
    UnitDef(id: 'legion', name: 'Legion', power: 10, cost: 36),
    UnitDef(id: 'battalion', name: 'Battalion', power: 20, cost: 64),
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