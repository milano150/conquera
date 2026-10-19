import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../services/server_clock.dart';
import '../theme/conquera_theme.dart';
import 'gold_amount.dart';
import 'player_tag.dart';
import 'stat_block.dart';

/// Full-width panel that sits directly under the top bar while a country
/// is selected. Same surface and divider as the bar, so the two read as
/// one header. The button on the right is "Manage" (opens the province
/// window), a red "Attack" when the country belongs to another player, or
/// a "Claim" when nobody owns it yet.
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

  /// Nobody owns the country: show Claim instead of Manage.
  final bool isUnclaimed;

  /// One of the player's provinces borders this country (needed to attack
  /// or claim it).
  final bool canAttack;

  /// False greys the Attack / Claim button out (no power to split).
  final bool canSplit;

  /// When the attack cooldown ends (null or past = ready).
  final DateTime? attackReadyAt;
  final VoidCallback? onAttack;
  final VoidCallback? onClaim;

  /// Icon of the USE button beside Manage (a missile silo's launch).
  /// Null = no button.
  final IconData? useIcon;
  final Color? useColor;
  final VoidCallback? onUse;

  /// When the building can be used again (null or past = ready). Shown
  /// as a countdown inside the USE button.
  final DateTime? useReadyAt;

  /// Gold price shown beside the USE icon (null = free / none), and whether
  /// the player can afford it (false disables the button).
  final int? useCost;
  final bool useEnabled;

  /// While a missile is being aimed the USE button turns into a red X that
  /// calls [onUseCancel].
  final bool useCancel;
  final VoidCallback? onUseCancel;

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
    this.isUnclaimed = false,
    this.canAttack = false,
    this.canSplit = true,
    this.attackReadyAt,
    this.onAttack,
    this.onClaim,
    this.useIcon,
    this.useColor,
    this.onUse,
    this.useReadyAt,
    this.useCost,
    this.useEnabled = true,
    this.useCancel = false,
    this.onUseCancel,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
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
                    _ActionButton(
                      label: 'Attack',
                      color: ConqueraColors.danger,
                      enabled: canAttack && canSplit,
                      readyAt: attackReadyAt,
                      hint: canAttack ? null : 'Not bordering your land',
                      onPressed: onAttack,
                    )
                  else if (isUnclaimed)
                    // Only offered when one of the player's provinces
                    // borders it; otherwise there is no button at all.
                    ...[
                      if (canAttack)
                        _ActionButton(
                          label: 'Claim',
                          price: GameRules.claimCost,
                          color: ConqueraColors.accent,
                          enabled: canSplit,
                          readyAt: null, // claiming has no cooldown
                          hint: null,
                          onPressed: onClaim,
                        ),
                    ]
                  else ...[
                    if (useIcon != null) ...[
                      _UseButton(
                        icon: useCancel ? Icons.close : useIcon!,
                        color: useColor ?? ConqueraColors.ink,
                        readyAt: useCancel ? null : useReadyAt,
                        cost: useCancel ? null : useCost,
                        onPressed:
                            useCancel ? onUseCancel : (useEnabled ? onUse : null),
                      ),
                      const SizedBox(width: ConqueraSpace.sm),
                    ],
                    OutlinedButton(
                      onPressed: onOpenDetails,
                      child: const Text('Manage'),
                    ),
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

/// The panel's action button (red Attack, blue Claim), hollow like Manage.
/// Disabled when none
/// of the player's provinces border the country; while the attack cooldown
/// runs it shows a countdown and ticks once a second on its own (so the
/// panel doesn't rebuild). [hint] is a small caption under the button.
class _ActionButton extends StatefulWidget {
  final String label;

  /// Gold price shown after the label (Claim); null for none.
  final int? price;
  final Color color;
  final bool enabled;
  final DateTime? readyAt;
  final String? hint;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.label,
    required this.color,
    required this.enabled,
    required this.readyAt,
    required this.hint,
    required this.onPressed,
    this.price,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _ActionButton oldWidget) {
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
    final left = ready.difference(ServerClock.now());
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
    final hint = widget.hint;
    final active = widget.enabled && !cooling;
    final price = widget.price;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Same size, font and shape as the Manage button (from the theme);
        // only the outline color tells the actions apart.
        OutlinedButton(
          onPressed: active ? widget.onPressed : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: widget.color,
            side: BorderSide(
              color: active ? widget.color : ConqueraColors.divider,
            ),
          ),
          child: cooling || price == null
              ? Text(cooling ? '${widget.label} ${_clock(left)}' : widget.label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.label),
                    const SizedBox(width: 6),
                    GoldAmount(price),
                  ],
                ),
        ),
        if (hint != null) ...[
          const SizedBox(height: ConqueraSpace.xs),
          Text(hint, style: ConqueraText.label),
        ],
      ],
    );
  }
}

/// The icon-only USE button. While the building reloads it shows the
/// time left next to the icon and goes muted.
class _UseButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final DateTime? readyAt;
  final int? cost;
  final VoidCallback? onPressed;

  const _UseButton({
    required this.icon,
    required this.color,
    required this.readyAt,
    required this.cost,
    required this.onPressed,
  });

  @override
  State<_UseButton> createState() => _UseButtonState();
}

class _UseButtonState extends State<_UseButton> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left() != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration? _left() {
    final at = widget.readyAt;
    if (at == null) return null;
    final d = at.difference(ServerClock.now());
    return d > Duration.zero ? d : null;
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${two(m)}m' : '${two(m)}:${two(sec)}';
  }

  @override
  Widget build(BuildContext context) {
    final left = _left();
    final color = left == null ? widget.color : ConqueraColors.muted;
    return OutlinedButton(
      onPressed: widget.onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: left == null ? color : ConqueraColors.divider),
        minimumSize: const Size(44, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(widget.icon, size: 20),
          if (left == null && widget.cost != null) ...[
            const SizedBox(width: 6),
            GoldAmount(
              widget.cost!,
              iconSize: 14,
              faded: widget.onPressed == null,
              style: ConqueraText.value.copyWith(
                color: color,
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (left != null) ...[
            const SizedBox(width: 6),
            Text(
              _fmt(left),
              style: ConqueraText.value.copyWith(
                color: color,
                fontSize: 13,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}