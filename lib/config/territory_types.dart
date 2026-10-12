/// What kind of place each territory is. Decides which buildings a province
/// may build (see [GameRules.buildingsFor]). Ids are the same ISO 3166-1
/// alpha-2 ids the SVG uses (the Caribbean Netherlands are BQBO, BQSA, BQSE).
///
/// Anything that is not landlocked counts as coastal, so the harbor is open
/// to every territory except the ones in [landlocked]. Island archipelagos
/// are coastal too.
class TerritoryTypes {
  TerritoryTypes._();

  /// No coast on the open ocean. (Kazakhstan, Turkmenistan and Azerbaijan
  /// only touch the Caspian, which is a lake, so they count as landlocked.)
  static const Set<String> landlocked = {
    // Europe
    'AT', 'BY', 'CH', 'CZ', 'HU', 'LU', 'MD', 'MK', 'RS', 'SK', 'XK',
    // Caucasus & Central Asia
    'AM', 'AZ', 'KZ', 'KG', 'TJ', 'TM', 'UZ',
    // Asia
    'AF', 'BT', 'LA', 'MN', 'NP',
    // Africa
    'BF', 'BI', 'BW', 'CF', 'ET', 'LS', 'ML', 'MW', 'NE', 'RW', 'SS', 'SZ',
    'TD', 'UG', 'ZM', 'ZW',
    // South America
    'BO', 'PY',
  };

  /// Small islands and island groups. Only these may build an offshore rig.
  static const Set<String> islandArchipelagos = {
    // Caribbean
    'AG', 'AI', 'AW', 'BB', 'BL', 'BM', 'BQBO', 'BQSA', 'BQSE', 'BS', 'CW',
    'DM', 'GD', 'GP', 'JM', 'KN', 'KY', 'LC', 'MF', 'MQ', 'MS', 'PR', 'SX',
    'TC', 'TT', 'VC', 'VG', 'VI',
    // Atlantic
    'CV', 'FK', 'FO', 'ST',
    // Indian Ocean & Gulf
    'BH', 'KM', 'MU', 'MV', 'RE', 'SC', 'YT',
    // Pacific
    'AS', 'FJ', 'FM', 'GU', 'MH', 'MP', 'NC', 'NR', 'PF', 'PW', 'SB', 'TO',
    'TV', 'VU', 'WS',
    // Mediterranean
    'CY', 'MT',
    // Big island nations and archipelagos. Delete this block if you want
    // rigs for the small ones only.
    'CU', 'GB', 'GL', 'ID', 'IE', 'IS', 'JP', 'LK', 'MG', 'NZ', 'PG', 'PH',
    'TW',
  };

  static bool isLandlocked(String provinceId) => landlocked.contains(provinceId);

  static bool isCoastal(String provinceId) => !isLandlocked(provinceId);

  static bool isIslandArchipelago(String provinceId) =>
      islandArchipelagos.contains(provinceId);
}