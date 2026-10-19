// Per-territory tuning for buildings: how much a building earns and whether
// it may be built, territory by territory. Edit only this file to rebalance;
// nothing here is stored in Firestore.
//
// Lookup order for a (building, territory) pair:
//   1. [byBuilding]   - an exact territory rule
//   2. [byGroup]      - a rule shared by a set of territories
//   3. nothing found  - the building's defaults from game_rules.dart
//
// Territory ids are the ISO 3166-1 alpha-2 ids the SVG uses (see
// territories.txt). Building ids are the `id:` values in game_rules.dart
// (gold_mine, fishing_harbor, offshore_rig, oil_field, diamond_mine, uranium_mine, silver_mine, market, ...).
import 'dart:math' show ln10, log;

import 'territory_types.dart';

class TerritoryRule {
  /// Multiplier on the building's income there (gold/sec and gold/sec per
  /// trading neighbor). 1 = normal, 2 = double, 0.5 = half.
  final double rate;

  /// false = this building can never be built here.
  /// true  = it can be built here even if its site rule (coastal, island)
  ///         would say no.
  /// null  = normal availability rules.
  final bool? allowed;

  const TerritoryRule({this.rate = 1, this.allowed});
}

class _Group {
  final Set<String> ids;
  final TerritoryRule rule;
  const _Group(this.ids, this.rule);
}

class BuildingOverrides {
  BuildingOverrides._();

  /// building id -> territory id -> rule.
  static final Map<String, Map<String, TerritoryRule>> byBuilding = {
    'gold_mine': _goldRules,
    'fishing_harbor': _fishRules,
    'offshore_rig': _rigRules,
    'oil_field': _fieldRules,
    'diamond_mine': _diamondRules,
    'uranium_mine': _uraniumRules,
    'silver_mine': _silverRules,
  };

  // --- Fishing harbors -------------------------------------------------------
  // Rate comes from real marine capture catch, in thousand tonnes per year.
  // Coastal territories missing from [_fishKt] have a small or unverified
  // catch and get the default in [defaultRate].
  //
  // Top 7 (CN ID PE RU US IN VN) are 2022 FAO SOFIA 2024 shares of the 79.7 Mt
  // global marine catch; the rest are rounded, approximate recent FAO figures.
  // They only need to rank regions.
  static const Map<String, double> _fishKt = {
    'CN': 11800, 'ID': 6900, 'PE': 5300, 'RU': 4700, 'US': 4200, 'IN': 3600,
    'VN': 3400, 'JP': 3000, 'NO': 2400, 'MM': 2000, 'PH': 1900, 'CL': 1800,
    'MX': 1500, 'MY': 1500, 'TH': 1300, 'MA': 1300, 'IS': 1300, 'KR': 1000,
    'TW': 900, 'AR': 800, 'DK': 800, 'ES': 800, 'CA': 800, 'EC': 700,
    'BR': 700, 'GB': 700, 'IR': 700, 'BD': 700, 'NG': 600, 'ZA': 600,
    'MR': 600, 'PK': 500, 'SN': 500, 'KP': 450, 'NZ': 400, 'NA': 400,
    'AO': 400, 'GH': 350, 'TR': 350, 'EG': 350, 'FO': 600, 'GL': 250,
    'VE': 250, 'FR': 400, 'PT': 200, 'IE': 200, 'SO': 150, 'OM': 200,
    'LK': 300, 'YE': 150, 'AU': 200, 'PG': 250, 'SB': 100, 'KI': 100,
    'FM': 100, 'CO': 130, 'PA': 150, 'NI': 30, 'HN': 40, 'GT': 40,
    'CR': 25, 'MZ': 120, 'TZ': 100, 'KE': 10, 'TN': 100, 'DZ': 100,
    'LY': 40, 'SA': 80, 'AE': 80, 'KW': 6, 'IQ': 25, 'CU': 20,
  };

  static const double _fishBase = 0.5; // rate at 10 kt/yr
  static const double _fishSlope = 0.6; // per factor of 10 in kt
  static const double _fishMin = 0.5;
  static const double _fishMax = 3;

  static double _fishRate(double kt) {
    final r = (_fishBase + _fishSlope * log(kt / 10) / ln10)
        .clamp(_fishMin, _fishMax);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _fishRules = {
    for (final e in _fishKt.entries)
      if (!TerritoryTypes.isLandlocked(e.key))
        e.key: TerritoryRule(rate: _fishRate(e.value)),
  };

  // --- Diamond mines ---------------------------------------------------------
  // Rate comes from real rough diamond output, in million carats per year.
  // Only territories listed in [_diamondMct] with at least [_diamondMin] can
  // build a mine. Russia, Botswana, Angola, DR Congo and Namibia are 2023
  // figures (Kimberley Process via Intelpoint); the others are rounded
  // approximations of recent output. They only need to rank regions.
  static const Map<String, double> _diamondMct = {
    'RU': 37.3, 'BW': 25.1, 'CA': 17, 'AO': 9.8, 'CD': 8.3, 'ZA': 5,
    'ZW': 4, 'NA': 2.4, 'SL': 0.5, 'LS': 0.4, 'GN': 0.2, 'TZ': 0.2,
    'BR': 0.1, 'GH': 0.1, 'CF': 0.1, 'GY': 0.1, 'AU': 0.1,
  };

  static const double _diamondMin = 0.1; // million carats
  static const double _diamondBase = 0.5; // rate at 0.05 million carats
  static const double _diamondSlope = 0.6; // per factor of 10
  static const double _diamondMax = 3;

  static double _diamondRate(double mct) {
    final r = (_diamondBase + _diamondSlope * log(mct / 0.05) / ln10)
        .clamp(0.5, _diamondMax);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _diamondRules = {
    for (final e in _diamondMct.entries)
      if (e.value >= _diamondMin)
        e.key: TerritoryRule(rate: _diamondRate(e.value), allowed: true),
  };

  // --- Uranium mines ---------------------------------------------------------
  // Rate comes from real uranium mine output, in tonnes of uranium per year.
  // Only territories listed in [_uraniumData] with at least [_uraniumMin] can
  // build a mine. 2024 figures from the World Nuclear Association (CN, IN,
  // UZ, ZA, UA are WNA estimates).
  static const Map<String, double> _uraniumData = {
    'KZ': 23270, 'CA': 14309, 'NA': 7333, 'AU': 4598, 'UZ': 4000,
    'RU': 2738, 'CN': 1600, 'NE': 962, 'IN': 500, 'UA': 288, 'US': 260,
    'ZA': 200,
  };

  static const double _uraniumMin = 100; // tU needed to build
  static const double _uraniumBase = 0.5; // rate at 50 tU
  static const double _uraniumSlope = 0.6; // per factor of 10

  static double _uraniumRate(double v) {
    final r = (_uraniumBase + _uraniumSlope * log(v / 50) / ln10)
        .clamp(0.5, 3.0);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _uraniumRules = {
    for (final e in _uraniumData.entries)
      if (e.value >= _uraniumMin)
        e.key: TerritoryRule(rate: _uraniumRate(e.value), allowed: true),
  };

  // --- Silver mines ---------------------------------------------------------
  // Rate comes from real silver mine output, in million ounces per year.
  // Only territories listed in [_silverData] with at least [_silverMin] can
  // build a mine. 2023 figures, top 20 producers, from the Silver Institute.
  static const Map<String, double> _silverData = {
    'MX': 202.2, 'CN': 109.3, 'PE': 107.1, 'CL': 52.0, 'BO': 42.6,
    'PL': 42.5, 'RU': 39.8, 'AU': 34.4, 'US': 32.0, 'AR': 26.0, 'IN': 23.8,
    'KZ': 16.6, 'SE': 12.6, 'ID': 10.3, 'MA': 8.8, 'UZ': 7.7, 'CA': 7.1,
    'PG': 4.3, 'ES': 3.7, 'BR': 3.3,
  };

  static const double _silverMin = 3; // Moz needed to build
  static const double _silverBase = 0.5; // rate at 1 Moz
  static const double _silverSlope = 0.6; // per factor of 10

  static double _silverRate(double v) {
    final r = (_silverBase + _silverSlope * log(v / 1) / ln10)
        .clamp(0.5, 3.0);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _silverRules = {
    for (final e in _silverData.entries)
      if (e.value >= _silverMin)
        e.key: TerritoryRule(rate: _silverRate(e.value), allowed: true),
  };

  // --- Offshore rigs and oil fields -----------------------------------------
  // Rate comes from real crude oil production, in thousand barrels per day
  // (kb/d). Offshore rigs are for island archipelagos (those missing from
  // [_oilKbd] get [_rigNoOil]). Oil fields are for non-island territories
  // with at least [_rigMinBuild] kb/d in [_oilKbd]; both use the same scale.
  //
  // Figures are NATIONAL crude + condensate totals, rounded and approximate
  // (about 2023-24, mostly US EIA / OPEC / Energy Institute), not offshore
  // only. They only need to rank regions: Gulf and North America rich, most
  // of Europe and Asia poor. UK 2025 Energy Intelligence; Indonesia 2024-25
  // SKK Migas; Barbados CIA World Factbook; Falklands: Sea Lion FID Dec 2025,
  // first oil 2028, ~50 kb/d peak.
  static const Map<String, double> _oilKbd = {
    // Americas
    'US': 13200, 'CA': 4600, 'MX': 1600, 'BR': 3400, 'VE': 900, 'CO': 770,
    'AR': 700, 'EC': 470, 'GY': 650, 'PE': 90, 'BO': 40, 'TT': 54, 'CU': 30,
    'BB': 1, 'FK': 25, // FK: not producing yet, half of the planned peak
    // Middle East
    'SA': 9000, 'IQ': 4200, 'AE': 3400, 'IR': 3300, 'KW': 2500, 'OM': 1000,
    'QA': 600, 'BH': 180, 'YE': 70, 'SY': 20,
    // Russia, Caspian
    'RU': 9300, 'KZ': 1800, 'AZ': 500, 'TM': 200,
    // Africa
    'NG': 1500, 'LY': 1200, 'AO': 1100, 'DZ': 900, 'EG': 550, 'GA': 220,
    'CG': 270, 'GH': 150, 'SS': 140, 'TD': 100, 'GQ': 70, 'CM': 70, 'SD': 60,
    'TN': 40,
    // Europe
    'NO': 1800, 'GB': 569, 'DK': 60, 'RO': 70,
    // Asia & Pacific
    'CN': 4200, 'IN': 600, 'ID': 580, 'MY': 350, 'AU': 400, 'VN': 180,
    'TH': 220, 'BN': 100, 'PG': 32, 'NZ': 7, 'PH': 0.9,
  };

  static const double _rigBase = 0.5;
  static const double _rigSlope = 0.6; // per factor of 10 in kb/d
  static const double _rigMin = 0.5;
  static const double _rigMax = 3;
  static const double _rigNoOil = 0.25;
  static const double _rigMinBuild = 30; // kb/d needed to build an oil field

  static double _rigRate(double kbd) {
    if (kbd <= 0) return _rigNoOil;
    final r = (_rigBase + _rigSlope * log(kbd) / ln10).clamp(_rigMin, _rigMax);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _rigRules = {
    for (final id in TerritoryTypes.islandArchipelagos)
      id: TerritoryRule(rate: _rigRate(_oilKbd[id] ?? 0)),
  };

  static final Map<String, TerritoryRule> _fieldRules = {
    for (final e in _oilKbd.entries)
      if (e.value >= _rigMinBuild && !TerritoryTypes.isIslandArchipelago(e.key))
        e.key: TerritoryRule(rate: _rigRate(e.value), allowed: true),
  };

  // --- Gold mines ----------------------------------------------------------
  // Rate comes from real gold mine production, in tonnes per year. Territories
  // missing from [_goldT] have no (or unverified, small) production and get
  // the building's default in [defaultRate].
  //
  // Mixed vintages, newest available per country:
  //  * 2024 World Gold Council / Metals Focus: CN RU AU CA US GH MX ID PE UZ
  //    ML ZA BF KZ BR SD GN CO CI TZ PG
  //  * 2023 USGS: ZW CD AR TR CL KG PH SR EC EG GY MN NZ ET
  //  * 2020-21 Metals Focus: BO VE DO NE MR LR MG SN LA BG FI SE
  static const Map<String, double> _goldT = {
    'CN': 380, 'RU': 330, 'AU': 284, 'CA': 202, 'US': 158, 'GH': 141,
    'MX': 140, 'ID': 140, 'PE': 137, 'UZ': 129, 'ML': 100, 'ZA': 99,
    'BF': 94, 'KZ': 87, 'BR': 84, 'SD': 74, 'GN': 68, 'CO': 66, 'CI': 58,
    'TZ': 52, 'PG': 50, 'ZW': 46.6, 'BO': 45.7, 'CD': 44, 'AR': 41,
    'TR': 36.3, 'CL': 35.8, 'VE': 35, 'NE': 33.4, 'KG': 32, 'PH': 31,
    'SR': 18.3, 'DO': 25.5, 'MR': 21.8, 'LR': 19.9, 'EC': 18, 'SN': 17.1,
    'MG': 15.9, 'MN': 14.9, 'EG': 14.7, 'GY': 13.4, 'BG': 9.7, 'FI': 9,
    'LA': 8.8, 'SE': 6.7, 'NZ': 6.1, 'ET': 4.2,
  };

  static const double _goldSlope = 1.0; // per factor of 10 in tonnes
  static const double _goldMin = 0.5;
  static const double _goldMax = 3;

  static double _goldRate(double tonnes) {
    final r = (0.5 + _goldSlope * log(tonnes) / ln10).clamp(_goldMin, _goldMax);
    return (r * 100).round() / 100;
  }

  static final Map<String, TerritoryRule> _goldRules = {
    for (final e in _goldT.entries)
      e.key: TerritoryRule(rate: _goldRate(e.value)),
  };

  /// Income multiplier for a building in a territory with no rule of its own.
  /// Buildings not listed here default to 1.
  static const Map<String, double> defaultRate = {
    'gold_mine': 0.25,
    'fishing_harbor': 0.25,
  };

  /// building id -> groups of territories sharing one rule. Exact rules in
  /// [byBuilding] win over these.
  static const Map<String, List<_Group>> byGroup = {
  };

  static TerritoryRule? _find(String buildingId, String? territoryId) {
    if (territoryId == null) return null;
    final exact = byBuilding[buildingId]?[territoryId];
    if (exact != null) return exact;
    final groups = byGroup[buildingId];
    if (groups == null) return null;
    for (final g in groups) {
      if (g.ids.contains(territoryId)) return g.rule;
    }
    return null;
  }

  /// Income multiplier for [buildingId] in [territoryId] (1 if untouched).
  static double rateOf(String buildingId, String? territoryId) {
    if (territoryId == null) return 1;
    return _find(buildingId, territoryId)?.rate ??
        defaultRate[buildingId] ??
        1;
  }

  /// true / false to force availability, null to use the normal rules.
  static bool? allowedOf(String buildingId, String? territoryId) =>
      _find(buildingId, territoryId)?.allowed;
}