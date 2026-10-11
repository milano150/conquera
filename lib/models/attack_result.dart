/// What happened in one attack, handed back to the map screen so it can play
/// the right animation.
class AttackResult {
  final bool won;

  /// Power on each side: everyone fighting for the attacker added together
  /// vs. the defending province (already boosted by a fortress, if it has
  /// one). Battles are pure subtraction: the higher side wins, and a tie
  /// goes to the defender.
  final double attackerPower;
  final double defenderPower;

  /// The attacker's provinces that took part (bordering ones plus barracks
  /// support).
  final List<String> fighterIds;

  /// The defender's barracks that helped defend the target.
  final List<String> defenderSupportIds;

  /// How many of the attacker's provinces took part.
  int get attackerProvinceCount => fighterIds.length;

  /// Win: the power left over (attacker minus defender), which is shared
  /// between the fighters and the annexed province in proportion to the
  /// troops each of them had. Loss: 0.
  final double powerAfter;

  /// Loss: power the defending province still has. Win: 0.
  final double defenderPowerLeft;

  /// Win: the annexed province had a building, and it was destroyed.
  final bool buildingDestroyed;

  const AttackResult({
    required this.won,
    required this.attackerPower,
    required this.defenderPower,
    required this.fighterIds,
    this.defenderSupportIds = const [],
    required this.powerAfter,
    required this.defenderPowerLeft,
    this.buildingDestroyed = false,
  });
}