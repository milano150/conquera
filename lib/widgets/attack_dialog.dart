import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/attack_result.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';
import 'player_tag.dart';

/// The battle window, in three steps:
///   1. Preview: X vs Y (X is every province the player owns that borders
///      the target, plus barracks that border one of those; Y is the target,
///      boosted if it has a fortress) and what the outcome will be (X minus Y,
///      no luck). Nothing has happened yet; the player can cancel or confirm.
///   2. Fight: after Confirm, a short animation while the attack resolves.
///   3. Result: Victory or Defeat.
///
/// The numbers shown are a snapshot taken when the window opens, so the
/// live data changing under it (the target flips owner the moment the
/// attack goes through) doesn't make the screen jump.
class AttackDialog extends StatefulWidget {
  final String gameId;
  final String uid;
  final String targetId;
  final String targetName;

  /// Every province that borders the target (not only the player's).
  final Set<String> neighborIds;

  /// Barracks the player owns that may join the attack: candidate province
  /// id -> the player's bordering provinces it touches.
  final Map<String, Set<String>> supportLinks;

  /// provinceId -> display name, to list the player's attacking provinces.
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, ProvinceState>> provinceStates;
  final ValueListenable<Map<String, PlayerState>> players;
  final FirestoreService firestore;

  const AttackDialog({
    super.key,
    required this.gameId,
    required this.uid,
    required this.targetId,
    required this.targetName,
    required this.neighborIds,
    required this.supportLinks,
    required this.provinceNames,
    required this.provinceStates,
    required this.players,
    required this.firestore,
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

class _AttackDialogState extends State<AttackDialog>
    with SingleTickerProviderStateMixin {
  /// The fight animation plays at least this long, even if the server
  /// answers faster.
  static const Duration _minFight = Duration(milliseconds: 1800);

  late final AnimationController _pulse;

  late final double _attackPower;
  late final List<_Line> _involved;
  late final double _defendPower;
  late final List<_Line> _defenderLines;
  late final PlayerState? _me;
  late final PlayerState? _defender;

  bool _confirmed = false;
  AttackResult? _result;
  String? _error;

  bool get _done => _result != null || _error != null;
  bool get _fighting => _confirmed && !_done;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );

    final states = widget.provinceStates.value;
    final players = widget.players.value;

    // Fighters: the player's bordering provinces, then barracks that border
    // one of them (they send their power even though they don't touch the
    // target).
    var power = 0.0;
    final direct = <({String text, int power})>[];
    final ownedBorders = <String>{};
    for (final id in widget.neighborIds) {
      final state = states[id];
      if (state != null && state.ownerId == widget.uid) {
        ownedBorders.add(id);
        power += state.troops;
        direct.add((
          text: '${widget.provinceNames[id] ?? id}  ${state.troops.floor()}',
          power: state.troops.floor(),
        ));
      }
    }
    final support = <({String text, int power, IconData? icon})>[];
    widget.supportLinks.forEach((id, links) {
      if (widget.neighborIds.contains(id)) return;
      final state = states[id];
      if (state == null || state.ownerId != widget.uid) return;
      if (!GameRules.supportsAttacks(state.buildingType)) return;
      if (!links.any(ownedBorders.contains)) return;
      power += state.troops;
      support.add((
        text: '${widget.provinceNames[id] ?? id}  ${state.troops.floor()}',
        power: state.troops.floor(),
        icon: GameRules.buildingById(state.buildingType)?.icon,
      ));
    });
    direct.sort((a, b) => b.power.compareTo(a.power));
    support.sort((a, b) => b.power.compareTo(a.power));
    _involved = [
      for (final d in direct) _Line(d.text),
      for (final s in support) _Line(s.text, icon: s.icon),
    ];

    final target = states[widget.targetId];
    final targetBuilding = target?.buildingType ?? 'none';
    final defenseMultiplier = GameRules.defenseMultiplier(targetBuilding);
    final defenseDef = GameRules.buildingById(targetBuilding);
    _attackPower = power;
    _defendPower = (target?.troops ?? 0) * defenseMultiplier;
    _defenderLines = [
      _Line(widget.targetName),
      if (defenseMultiplier > 1 && defenseDef != null)
        _Line(
          '${defenseDef.name} +${((defenseMultiplier - 1) * 100).round()}%',
          icon: defenseDef.icon,
        ),
    ];
    _me = players[widget.uid];
    _defender = players[target?.ownerId];
  }

  /// Battles are plain subtraction: the attacker wins only with strictly more
  /// power than the defender.
  bool get _wouldWin => _attackPower > _defendPower;

  /// Each side's share of the total power, for the bar in the preview.
  double get _powerShare {
    final total = _attackPower + _defendPower;
    return total <= 0 ? 0.5 : _attackPower / total;
  }

  void _confirm() {
    if (_confirmed) return;
    setState(() => _confirmed = true);
    _pulse.repeat(reverse: true);
    _fight();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _fight() async {
    final started = DateTime.now();
    AttackResult? result;
    String? error;
    try {
      result = await widget.firestore.attackProvince(
        gameId: widget.gameId,
        uid: widget.uid,
        targetId: widget.targetId,
        neighborIds: widget.neighborIds,
      );
    } on GameActionException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('Attack failed: $e');
      error = 'Something went wrong. Try again.';
    }

    if (error == null) {
      final wait = _minFight - DateTime.now().difference(started);
      if (!wait.isNegative) await Future<void>.delayed(wait);
    }
    if (!mounted) return;
    _pulse.stop();
    setState(() {
      _result = result;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;

    return PopScope(
      canPop: !_fighting,
      child: Dialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(ConqueraSpace.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: ConqueraColors.divider),
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
                  'Attack ${widget.targetName}',
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
                        lines: _defenderLines,
                      ),
                    ),
                  ],
                ),
                if (_error == null) ...[
                  const SizedBox(height: ConqueraSpace.md),
                  _bar(),
                ],
                const SizedBox(height: ConqueraSpace.md),
                _status(result),
                const SizedBox(height: ConqueraSpace.md),
                _buttons(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buttons() {
    if (_fighting) return const SizedBox.shrink();

    if (_done) {
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: ConqueraSpace.sm),
        FilledButton(
          onPressed: _attackPower > 0 ? _confirm : null,
          style: FilledButton.styleFrom(
            backgroundColor: ConqueraColors.danger,
            foregroundColor: Colors.white,
            disabledBackgroundColor: ConqueraColors.divider.withAlpha(90),
            disabledForegroundColor: ConqueraColors.muted,
          ),
          child: const Text('Confirm attack'),
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
  }) {
    return Column(
      crossAxisAlignment: align,
      children: [
        tag,
        const SizedBox(height: ConqueraSpace.xs),
        Text(
          '${power.floor()}',
          style: ConqueraText.figure.copyWith(fontSize: 36),
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

  /// Tug-of-war bar: shows each side's share of the power in the preview,
  /// wobbles while the fight runs, then tips toward the winner.
  Widget _bar() {
    final left = _me?.color ?? ConqueraColors.accent;
    final right = _defender?.color ?? ConqueraColors.muted;

    Widget paint(double fraction) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: 10,
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                Container(
                  width: (box.maxWidth - 2) * fraction.clamp(0.0, 1.0),
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

    // Preview: the bar is each side's share of the power.
    if (!_confirmed) return paint(_powerShare);

    final result = _result;
    if (result == null) {
      return AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => paint(0.42 + 0.16 * _pulse.value),
      );
    }

    // After the fight the bar just tips toward the winner.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.5, end: result.won ? 0.85 : 0.15),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      builder: (context, fraction, _) => paint(fraction),
    );
  }

  Widget _status(AttackResult? result) {
    if (_error != null) {
      return Text(
        _error!,
        style: ConqueraText.value.copyWith(color: ConqueraColors.danger),
      );
    }
    if (!_confirmed) {
      if (_attackPower <= 0) {
        return Text(
          'Your bordering provinces have no power.',
          style: ConqueraText.label.copyWith(color: ConqueraColors.danger),
        );
      }
      if (_wouldWin) {
        final left = (_attackPower - _defendPower).floor();
        return Text(
          'You win with $left power left over.',
          style: ConqueraText.value.copyWith(fontWeight: FontWeight.w600),
        );
      }
      return Text(
        'Not enough power: this attack would fail.',
        style: ConqueraText.value.copyWith(
          fontWeight: FontWeight.w600,
          color: ConqueraColors.danger,
        ),
      );
    }
    if (result == null) {
      return Text('The armies clash...', style: ConqueraText.label);
    }

    final cooldown = GameRules.attackCooldown.inSeconds;
    final headline = result.won ? 'Victory' : 'Defeat';
    final color = result.won ? ConqueraColors.accent : ConqueraColors.danger;
    final detail = result.won
        ? '${widget.targetName} is annexed.'
            '${result.buildingDestroyed ? ' Its building was destroyed.' : ''}'
        : 'Your attack on ${widget.targetName} failed.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline, style: ConqueraText.name.copyWith(color: color)),
        const SizedBox(height: ConqueraSpace.xs),
        Text(detail, style: ConqueraText.value),
        const SizedBox(height: ConqueraSpace.xs),
        Text('Next attack in $cooldown seconds.', style: ConqueraText.label),
      ],
    );
  }
}