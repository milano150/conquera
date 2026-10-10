/// What happened in one attack, handed back to the battle window.
class AttackResult {
  final bool won;

  /// Power on each side: everyone fighting for the attacker added together
  /// vs. the defending province (already boosted by a fortress, if it has
  /// one). Battles are pure subtraction: the higher side wins, and a tie
  /// goes to the defender.
  final double attackerPower;
  final double defenderPower;

  /// How many of the attacker's provinces took part (bordering ones plus
  /// barracks support).
  final int attackerProvinceCount;

  /// Win: power each of the attacker's provinces (and the annexed one)
  /// holds after the leftover power (attacker minus defender) is spread
  /// evenly. Loss: 0.
  final double powerAfter;

  /// Loss: power the defending province still has. Win: 0.
  final double defenderPowerLeft;

  /// Win: the annexed province had a building, and it was destroyed.
  final bool buildingDestroyed;

  const AttackResult({
    required this.won,
    required this.attackerPower,
    required this.defenderPower,
    required this.attackerProvinceCount,
    required this.powerAfter,
    required this.defenderPowerLeft,
    this.buildingDestroyed = false,
  });
}