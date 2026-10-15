import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../theme/conquera_theme.dart';

/// A plain read-through of the game, in the order a new player meets it.
class HowToPlayScreen extends StatelessWidget {
  const HowToPlayScreen({super.key});

  static final List<(String, String)> _sections = [
    (
      'Your first territory',
      'When you join a world, the game picks a free country at random and '
          'makes it yours. You start with ${GameRules.startingGold} gold and '
          '${GameRules.startingTroops.toInt()} power in that territory. It '
          'shows on the map in your color, and everything you do from here '
          'grows outward from it.',
    ),
    (
      'Gold',
      'Gold is what you spend on everything. Every territory you own earns a '
          'little gold every second, and buildings add more on top. Your '
          'income is shown in the bar at the top of the screen. Early gold '
          'is the most valuable, because what you build now keeps paying '
          'you back.',
    ),
    (
      'Power',
      'Power is the strength of the army in a territory. Tap a territory to '
          'open it and buy units: a squad gives +5 power for 10 gold, a '
          'legion +10 for 18, and a battalion +20 for 32. Bigger units cost '
          'less per point of power. One power always stays behind as a '
          'garrison, so a territory needs at least '
          '${GameRules.minPowerToAct.toInt()} power to attack or claim.',
    ),
    (
      'Claiming land',
      'A bordering territory that nobody owns can be claimed for '
          '${GameRules.claimCost} gold. Sea links count as borders, so '
          'islands and far coasts can be reachable too. Claiming has no '
          'cooldown.',
    ),
    (
      'Attacking',
      'To take land from another player, attack one of their territories '
          'that borders one of yours. If your power beats theirs, the '
          'territory becomes yours. If you fail, both sides lose troops: '
          'each fighting province loses '
          '${(GameRules.failedAttackLossShare * 100).round()}% of its '
          'power, and the defence loses the same total amount. After any '
          'attack you must wait ${GameRules.attackCooldown.inMinutes} '
          'minutes before the next one.',
    ),
    (
      'Buildings',
      'Each territory can hold one building. Gold mines, fishing harbors '
          '(coast only), offshore rigs (island archipelagos only) and '
          'markets make gold, and a market earns more for every bordering '
          'territory you also own. Barracks lend their power to attacks '
          'launched from bordering territories of yours, and a radar shows '
          'the buildings and power of the territories around it. If you '
          'destroy a building, you cannot build anything for '
          '${GameRules.buildCooldownAfterDestroy.inMinutes} minutes.',
    ),
    (
      'Defending',
      'A fortress makes a territory 50% harder to invade. A wall triples '
          'its power when invaded, but a territory with a wall cannot '
          'attack or claim, so walls suit borders you only want to hold.',
    ),
    (
      'The war log',
      'Open Updates in the menu to see every war you started or faced and '
          'every building you built or destroyed, newest at the bottom.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ConqueraColors.land,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ConqueraSpace.sm,
                ConqueraSpace.sm,
                ConqueraSpace.md,
                ConqueraSpace.sm,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, size: 20),
                    color: ConqueraColors.ink,
                  ),
                  Text(
                    'How to play',
                    style: ConqueraText.title.copyWith(fontSize: 22),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: ConqueraColors.divider),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(ConqueraSpace.md),
                children: [
                  for (final (title, body) in _sections) ...[
                    Text(title, style: ConqueraText.name),
                    const SizedBox(height: ConqueraSpace.xs),
                    Text(
                      body,
                      style: ConqueraText.value.copyWith(
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: ConqueraSpace.lg),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}