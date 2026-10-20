import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../theme/conquera_theme.dart';
import 'player_tag.dart';

/// The battle preview: X vs Y (X is every province the player owns that
/// borders the target, plus barracks that border one of those; Y is the
/// target, boosted if it has a fortress). Nothing has happened yet; the
/// player can cancel or confirm.
///
/// Confirm closes the window right away, returning the ids of the provinces
/// that will fight (`Set<String>`); the map screen then runs the attack and
/// plays the animations. Cancel returns null.
///
/// The numbers shown are a snapshot taken when the window opens.
class AttackDialog extends StatefulWidget {
  final String uid;
  final String targetId;
  final String targetName;

  /// Every province that borders the target (not only the player's).
  final Set<String> neighborIds;

  /// True if a radar already shows the target's power and buildings.
  final bool targetVisible;

  /// Barracks the player owns that may join the attack: candidate province
  /// id -> the player's bordering provinces it touches.
  final Map<String, Set<String>> supportLinks;

  /// provinceId -> display name, to list the player's attacking provinces.
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, ProvinceState>> provinceStates;
  final ValueListenable<Map<String, PlayerState>> players;

  /// Set for a naval attack: the naval base whose navy fights (instead of
  /// the bordering provinces).
  final String? navalBaseId;

  const AttackDialog({
    super.key,
    required this.uid,
    required this.targetId,
    required this.targetName,
    required this.neighborIds,
    this.targetVisible = false,
    required this.supportLinks,
    required this.provinceNames,
    required this.provinceStates,
    required this.players,
    this.navalBaseId,
  });

  @override
  State<AttackDialog> createState() => _AttackDialogState();
}

/// One line under a side's power figure: text with an optional small icon
/// (a barracks supporting the attack, a fortress defending).
class _Line {
  final String text;
  final IconData? icon;

  const _Line(this.text, {this.icon});
}

class _AttackDialogState extends State<AttackDialog> {
  late final double _attackPower;
  late final Set<String> _fighterIds;
  late final List<_Line> _involved;
  late final double _defendPower;
  late final List<_Line> _defenderLines;
  late final PlayerState? _me;
  late final PlayerState? _defender;

  /// The defender's power and buildings stay hidden (fog of war) until the
  /// attack is confirmed.
  late bool _revealed = widget.targetVisible;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();

    final states = widget.provinceStates.value;
    final players = widget.players.value;

    // Fighters: the player's bordering provinces, then barracks that border
    // one of them (they send their power even though they don't touch the
    // target).
    var power = 0.0;
    final fighters = <String>{};
    final direct = <({String text, int power})>[];
    final ownedBorders = <String>{};
    final baseId = widget.navalBaseId;
    if (baseId != null) {
      // Naval attack: only the base's navy fights.
      final navy = states[baseId]?.navy ?? 0;
      if (GameRules.canAct(navy)) {
        fighters.add(baseId);
        power += navy;
      }
    }
    for (final id in baseId != null ? const <String>[] : widget.neighborIds) {
      final state = states[id];
      if (state != null && state.ownerId == widget.uid) {
        // Still counts as a bordering province a barracks can link to, but
        // with only 1 power it doesn't fight.
        ownedBorders.add(id);
        if (!GameRules.canFight(state.troops, state.buildingType)) continue;
        fighters.add(id);
        power += state.troops;
        direct.add((
          text: '${widget.provinceNames[id] ?? id}  ${state.troops.floor()}',
          power: state.troops.floor(),
        ));
      }
    }
    final support = <({String text, int power, IconData? icon})>[];
    if (baseId == null) widget.supportLinks.forEach((id, links) {
      if (widget.neighborIds.contains(id)) return;
      final state = states[id];
      if (state == null || state.ownerId != widget.uid) return;
      if (!GameRules.supportsAttacks(state.buildingType)) return;
      if (!links.any(ownedBorders.contains)) return;
      if (!GameRules.canAct(state.troops)) return;
      fighters.add(id);
      power += state.troops;
      support.add((
        text: '${widget.provinceNames[id] ?? id}  ${state.troops.floor()}',
        power: state.troops.floor(),
        icon: GameRules.buildingById(state.buildingType)?.icon,
      ));
    });
    direct.sort((a, b) => b.power.compareTo(a.power));
    support.sort((a, b) => b.power.compareTo(a.power));
    _fighterIds = fighters;
    _involved = [
      if (baseId != null)
        _Line(
          '${widget.provinceNames[baseId] ?? baseId}  '
          '${(states[baseId]?.navy ?? 0).floor()} navy',
          icon: Icons.sailing,
        ),
      for (final d in direct) _Line(d.text),
      for (final s in support) _Line(s.text, icon: s.icon),
    ];

    final target = states[widget.targetId];
    final targetBuilding = target?.buildingType ?? 'none';
    final defenseMultiplier = GameRules.defenseMultiplier(targetBuilding);
    final defenseDef = GameRules.buildingById(targetBuilding);

    // The defender's barracks that border the target defend it too.
    var supportPower = 0.0;
    final defenderSupport = <({String text, int power, IconData? icon})>[];
    final defenderId = target?.ownerId;
    if (defenderId != null && baseId == null) {
      for (final id in widget.neighborIds) {
        if (id == widget.targetId) continue;
        final state = states[id];
        if (state == null || state.ownerId != defenderId) continue;
        if (!GameRules.supportsAttacks(state.buildingType)) continue;
        supportPower += state.troops;
        defenderSupport.add((
          text: '${widget.provinceNames[id] ?? id}  ${state.troops.floor()}',
          power: state.troops.floor(),
          icon: GameRules.buildingById(state.buildingType)?.icon,
        ));
      }
    }
    defenderSupport.sort((a, b) => b.power.compareTo(a.power));

    _attackPower = power;
    final defenseBonusPower = (target?.troops ?? 0) * (defenseMultiplier - 1);
    _defendPower = (target?.troops ?? 0) * defenseMultiplier + supportPower;
    _defenderLines = [
      _Line(widget.targetName),
      if (defenseMultiplier > 1 && defenseDef != null)
        _Line(
          '${defenseDef.name} +${defenseBonusPower.floor()} power '
          '(x${defenseMultiplier.toStringAsFixed(defenseMultiplier % 1 == 0 ? 0 : 1)})',
          icon: defenseDef.icon,
        ),
      for (final s in defenderSupport) _Line(s.text, icon: s.icon),
    ];
    _me = players[widget.uid];
    _defender = players[target?.ownerId];
  }

  /// Battles are plain subtraction: the attacker wins only with strictly more
  /// power than the defender.
  bool get _wouldWin => _attackPower > _defendPower;

  /// Each side's share of the total power, for the bar.
  double get _powerShare {
    if (!_revealed) return 0.5;
    final total = _attackPower + _defendPower;
    return total <= 0 ? 0.5 : _attackPower / total;
  }

  /// Closes the window and hands the fighters to the map screen.
  void _confirm() {
    if (widget.targetVisible) {
      Navigator.of(context).pop(_fighterIds);
      return;
    }
    if (_confirming) return;
    setState(() {
      _confirming = true;
      _revealed = true;
    });
    // Let the player see what they are up against before the fight starts.
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) Navigator.of(context).pop(_fighterIds);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(ConqueraSpace.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: ConqueraColors.divider),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ConqueraSpace.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.navalBaseId != null
                      ? 'Naval attack on ${widget.targetName}'
                      : 'Attack ${widget.targetName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.title,
                ),
                const SizedBox(height: ConqueraSpace.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _side(
                        align: CrossAxisAlignment.start,
                        textAlign: TextAlign.start,
                        tag: PlayerTag(
                          name: _me?.displayName ?? 'You',
                          color: _me?.color,
                        ),
                        power: _attackPower,
                        powerColor:
                            widget.navalBaseId != null ? GameRules.navyColor : null,
                        lines: _involved,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ConqueraSpace.sm,
                        28,
                        ConqueraSpace.sm,
                        0,
                      ),
                      child: Text(
                        'VS',
                        style: ConqueraText.label.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _side(
                        align: CrossAxisAlignment.end,
                        textAlign: TextAlign.end,
                        tag: PlayerTag(
                          name: _defender?.displayName ?? 'Defender',
                          color: _defender?.color,
                        ),
                        power: _defendPower,
                        hidden: !_revealed,
                        lines: _revealed
                            ? _defenderLines
                            : [_Line(widget.targetName)],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: ConqueraSpace.md),
                _bar(),
                if (_attackPower <= 0) ...[
                  const SizedBox(height: ConqueraSpace.md),
                  _warning(),
                ],
                const SizedBox(height: ConqueraSpace.md),
                _buttons(),
              ],
            ),
          ),
        ),
      );
  }

  Widget _buttons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _confirming ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: ConqueraSpace.sm),
        OutlinedButton(
          onPressed: _attackPower > 0 && !_confirming ? _confirm : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: ConqueraColors.danger,
            side: BorderSide(
              color: _attackPower > 0
                  ? ConqueraColors.danger
                  : ConqueraColors.divider,
            ),
          ),
          child: Text(
            widget.navalBaseId != null ? 'Launch naval attack' : 'Confirm attack',
          ),
        ),
      ],
    );
  }

  Widget _side({
    required CrossAxisAlignment align,
    required TextAlign textAlign,
    required Widget tag,
    required double power,
    required List<_Line> lines,
    Color? powerColor,
    bool hidden = false,
  }) {
    return Column(
      crossAxisAlignment: align,
      children: [
        tag,
        const SizedBox(height: ConqueraSpace.xs),
        Text(
          hidden ? '?' : '${power.floor()}',
          style: ConqueraText.figure.copyWith(fontSize: 36, color: powerColor),
        ),
        for (final line in lines)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (line.icon != null) ...[
                Icon(line.icon, size: 13, color: ConqueraColors.muted),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  line.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: textAlign,
                  style: ConqueraText.label,
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// Tug-of-war bar: each side's share of the power.
  Widget _bar() {
    final left = _me?.color ?? ConqueraColors.accent;
    final right = _defender?.color ?? ConqueraColors.muted;

    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: 10,
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Container(
                width: (box.maxWidth - 2) * _powerShare.clamp(0.0, 1.0),
                color: left,
              ),
              Container(width: 2, color: ConqueraColors.surface),
              Expanded(child: Container(color: right)),
            ],
          ),
        ),
      ),
    );
  }

  /// Only shown when none of your bordering provinces has any power. A
  /// weak or winning attack needs no text: the bar already says it.
  Widget _warning() {
    return Text(
      widget.navalBaseId != null
          ? 'Your navy has no power.'
          : 'Your bordering provinces have no power.',
      style: ConqueraText.label.copyWith(color: ConqueraColors.danger),
    );
  }
}