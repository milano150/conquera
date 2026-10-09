import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';
import 'player_tag.dart';
import 'stat_block.dart';

/// Full-width panel that sits directly under the top bar while a country
/// is selected. Same surface and divider as the bar, so the two read as
/// one header. The button on the right is "Manage" (opens the province
/// window), or a red "Attack" when the country belongs to another player.
class CountryInfoPanel extends StatelessWidget {
  final String name;

  /// Null means the country is unclaimed.
  final String? ownerName;
  final Color? ownerColor;
  final String power;
  final String building;
  final VoidCallback onClose;
  final VoidCallback onOpenDetails;

  /// The country belongs to another player: show Attack instead of Manage.
  final bool isEnemy;

  /// One of the player's provinces borders this country.
  final bool canAttack;

  /// When the attack cooldown ends (null or past = ready).
  final DateTime? attackReadyAt;
  final VoidCallback? onAttack;

  const CountryInfoPanel({
    super.key,
    required this.name,
    required this.ownerName,
    required this.ownerColor,
    required this.power,
    required this.building,
    required this.onClose,
    required this.onOpenDetails,
    this.isEnemy = false,
    this.canAttack = false,
    this.attackReadyAt,
    this.onAttack,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ConqueraColors.surface,
        border: Border(bottom: BorderSide(color: ConqueraColors.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ConqueraSpace.md,
          ConqueraSpace.sm,
          ConqueraSpace.sm,
          ConqueraSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConqueraText.title,
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  color: ConqueraColors.muted,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: ConqueraSpace.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: ConqueraSpace.xl,
                      runSpacing: ConqueraSpace.md,
                      children: [
                        StatBlock(
                          label: 'Owner',
                          child: PlayerTag(
                            name: ownerName ?? 'Unclaimed',
                            color: ownerColor,
                            style: ownerName == null
                                ? ConqueraText.value
                                    .copyWith(color: ConqueraColors.muted)
                                : ConqueraText.value,
                          ),
                        ),
                        StatBlock(
                          label: 'Power',
                          child: Text(power, style: ConqueraText.value),
                        ),
                        StatBlock(
                          label: 'Building',
                          child: Text(building, style: ConqueraText.value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: ConqueraSpace.sm),
                  if (isEnemy)
                    _AttackButton(
                      enabled: canAttack,
                      readyAt: attackReadyAt,
                      onPressed: onAttack,
                    )
                  else
                    OutlinedButton(
                      onPressed: onOpenDetails,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Manage'),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward, size: 16),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The red Attack button. Disabled when none of the player's provinces
/// border the country; while the cooldown runs it shows a countdown and
/// ticks once a second on its own (so the panel doesn't rebuild).
class _AttackButton extends StatefulWidget {
  final bool enabled;
  final DateTime? readyAt;
  final VoidCallback? onPressed;

  const _AttackButton({
    required this.enabled,
    required this.readyAt,
    required this.onPressed,
  });

  @override
  State<_AttackButton> createState() => _AttackButtonState();
}

class _AttackButtonState extends State<_AttackButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _AttackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readyAt != widget.readyAt) _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Duration _left() {
    final ready = widget.readyAt;
    if (ready == null) return Duration.zero;
    final left = ready.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (_left() <= Duration.zero) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {});
      if (_left() <= Duration.zero) timer.cancel();
    });
  }

  String _clock(Duration d) {
    final secs = (d.inMilliseconds / 1000).ceil();
    return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final left = _left();
    final cooling = left > Duration.zero;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FilledButton(
          onPressed: widget.enabled && !cooling ? widget.onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: ConqueraColors.danger,
            foregroundColor: Colors.white,
            disabledBackgroundColor: ConqueraColors.divider.withAlpha(90),
            disabledForegroundColor: ConqueraColors.muted,
            minimumSize: const Size(0, 36),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(cooling ? 'Attack ${_clock(left)}' : 'Attack'),
              const SizedBox(width: 6),
              const Icon(Icons.bolt, size: 16),
            ],
          ),
        ),
        if (!widget.enabled) ...[
          const SizedBox(height: ConqueraSpace.xs),
          Text('Not bordering your land', style: ConqueraText.label),
        ],
      ],
    );
  }
}