/// What happened in one attack, handed back to the battle window.
class AttackResult {
  final bool won;

  /// Power on each side before luck: everyone fighting for the attacker
  /// added together vs. the defending province (already boosted by a
  /// fortress, if it has one).
  final double attackerPower;
  final double defenderPower;

  /// Power after the luck roll. Whoever is higher wins (a tie goes to the
  /// defender).
  final double attackerStrength;
  final double defenderStrength;

  /// How many of the attacker's provinces took part (bordering ones plus
  /// barracks support).
  final int attackerProvinceCount;

  /// Win: power each of the attacker's provinces (and the annexed one)
  /// holds after the power is spread evenly. Loss: 0.
  final double powerAfter;

  /// Loss: power the defending province still has. Win: 0.
  final double defenderPowerLeft;

  const AttackResult({
    required this.won,
    required this.attackerPower,
    required this.defenderPower,
    required this.attackerStrength,
    required this.defenderStrength,
    required this.attackerProvinceCount,
    required this.powerAfter,
    required this.defenderPowerLeft,
  });

  /// Luck as a fraction, e.g. 0.07 = +7%.
  double get attackerLuck =>
      attackerPower <= 0 ? 0 : attackerStrength / attackerPower - 1;
  double get defenderLuck =>
      defenderPower <= 0 ? 0 : defenderStrength / defenderPower - 1;
}