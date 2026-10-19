/// Display names for territories whose names in the SVG are long or odd
/// ("Russian Federation", "Dem. Rep. Korea", "Faeroe Islands"...). Keyed by
/// the territory id; anything not listed keeps the name from the SVG.
/// The admin page (conquera_admin.html) has the same table in NAMES.
class TerritoryNames {
  const TerritoryNames._();

  static const Map<String, String> overrides = {
    'KP': "North Korea",
    'KR': "South Korea",
    'LA': "Laos",
    'RU': "Russia",
    'FO': "Faroe Islands",
    'BQBO': "Bonaire",
    'BQSA': "Saba",
    'BQSE': "Sint Eustatius",
    'BN': "Brunei",
    'CZ': "Czechia",
    'CI': "Ivory Coast",
    'CD': "DR Congo",
    'CG': "Congo",
    'FM': "Micronesia",
    'MK': "North Macedonia",
    'SZ': "Eswatini",
    'GM': "Gambia",
    'ST': "São Tomé and Príncipe",
    'RE': "Réunion",
    'BL': "Saint Barthélemy",
    'MF': "Saint Martin",
    'VI': "US Virgin Islands",
    'TL': "East Timor",
    'CV': "Cape Verde",
  };

  /// The name to show for [id], falling back to [svgName].
  static String of(String id, String svgName) => overrides[id] ?? svgName;
}