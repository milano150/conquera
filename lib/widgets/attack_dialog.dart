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
///      the target, Y is the target) and the player's chance to win. Nothing
///      has happened yet; the player can cancel or confirm.
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
    required this.provinceNames,
    required this.provinceStates,
    required this.players,
    required this.firestore,
  });

  @override
  State<AttackDialog> createState() => _AttackDialogState();
}

class _AttackDialogState extends State<AttackDialog>
    with SingleTickerProviderStateMixin {
  /// The fight animation plays at least this long, even if the server
  /// answers faster.
  static const Duration _minFight = Duration(milliseconds: 1800);

  late final AnimationController _pulse;

  late final double _attackPower;
  late final List<({String name, int power})> _involved;
  late final double _defendPower;
  late final PlayerState? _me;
  late final PlayerState? _defender;
  late final double _winChance;

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

    var power = 0.0;
    final involved = <({String name, int power})>[];
    for (final id in widget.neighborIds) {
      final state = states[id];
      if (state != null && state.ownerId == widget.uid) {
        power += state.troops;
        involved.add((
          name: widget.provinceNames[id] ?? id,
          power: state.troops.floor(),
        ));
      }
    }
    involved.sort((a, b) => b.power.compareTo(a.power));
    final target = states[widget.targetId];
    _attackPower = power;
    _involved = involved;
    _defendPower = target?.troops ?? 0;
    _me = players[widget.uid];
    _defender = players[target?.ownerId];
    _winChance = _chanceToWin(_attackPower, _defendPower);
  }

  /// Probability that the attacker wins once both luck rolls are made,
  /// worked out by stepping through every combination of the two rolls.
  static double _chanceToWin(double attack, double defend) {
    if (attack <= 0) return 0;
    if (defend <= 0) return 1;
    const steps = 200;
    final luck = GameRules.attackLuck;
    var wins = 0;
    for (var i = 0; i < steps; i++) {
      final a = attack * (1 + (((i + 0.5) / steps) * 2 - 1) * luck);
      for (var j = 0; j < steps; j++) {
        final d = defend * (1 + (((j + 0.5) / steps) * 2 - 1) * luck);
        if (a > d) wins++;
      }
    }
    return wins / (steps * steps);
  }

  int get _winPercent {
    if (_winChance >= 1) return 100;
    if (_winChance <= 0) return 0;
    return (_winChance * 100).round().clamp(1, 99);
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
                        lines: [
                          for (final p in _involved) '${p.name}  ${p.power}',
                        ],
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
                        lines: [widget.targetName],
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
    required List<String> lines,
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
          Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: ConqueraText.label,
          ),
      ],
    );
  }

  /// Tug-of-war bar: wobbles while the fight runs, then settles on each
  /// side's share of the luck-adjusted strength.
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

    // Preview: the bar is the chance to win.
    if (!_confirmed) return paint(_winChance);

    final result = _result;
    if (result == null) {
      return AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => paint(0.42 + 0.16 * _pulse.value),
      );
    }

    // The luck rolls stay hidden: the bar just tips toward the winner.
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
      return Row(
        children: [
          Text('Chance to win ', style: ConqueraText.label),
          Text(
            '$_winPercent%',
            style: ConqueraText.value.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_attackPower <= 0) ...[
            const SizedBox(width: ConqueraSpace.sm),
            Expanded(
              child: Text(
                'Your bordering provinces have no power.',
                style: ConqueraText.label.copyWith(color: ConqueraColors.danger),
              ),
            ),
          ],
        ],
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