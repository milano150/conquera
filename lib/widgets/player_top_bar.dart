import 'dart:async';

import 'package:flutter/material.dart';

import '../models/player_state.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';
import 'gold_amount.dart';
import 'player_tag.dart';

/// Top bar: menu button on the left, the player in the middle, gold on the
/// right. The two sides take equal room, so the player stays centered.
///
/// Gold is computed locally from the stored snapshot (see
/// [PlayerState.goldAt]) and refreshed once a second, so it ticks up
/// without any Firestore writes.
class PlayerTopBar extends StatefulWidget implements PreferredSizeWidget {
  final String gameId;
  final String uid;

  /// The menu (three lines) button was tapped.
  final VoidCallback onMenuPressed;

  const PlayerTopBar({
    super.key,
    required this.gameId,
    required this.uid,
    required this.onMenuPressed,
  });

  static const double height = 56;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  State<PlayerTopBar> createState() => _PlayerTopBarState();
}

class _PlayerTopBarState extends State<PlayerTopBar> {
  late final Stream<PlayerState?> _stream;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _stream = FirestoreService()
        .watchPlayer(gameId: widget.gameId, uid: widget.uid);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ConqueraColors.surface,
        border: Border(bottom: BorderSide(color: ConqueraColors.divider)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: PlayerTopBar.height,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: ConqueraSpace.md),
            child: StreamBuilder<PlayerState?>(
              stream: _stream,
              builder: (context, snapshot) {
                final player = snapshot.data;
                return Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          onPressed: widget.onMenuPressed,
                          tooltip: 'Menu',
                          icon: const Icon(Icons.menu, size: 24),
                          color: ConqueraColors.ink,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: PlayerTag(
                        name: player?.displayName ?? '...',
                        color: player?.color,
                        rectangle: true,
                      ),
                    ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _GoldReadout(
                          gold: player?.goldAt(DateTime.now()),
                          rate: player?.goldRate,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Coin, current gold, and income rate in one line.
class _GoldReadout extends StatelessWidget {
  final double? gold;
  final double? rate;

  const _GoldReadout({required this.gold, required this.rate});

  static String _thousands(double value) {
    final digits = value.floor().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  static String _trim(double v) =>
      v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1);

  /// Slow idle rates read better per minute than as 0.1/s.
  static String _rateLabel(double perSecond) {
    return perSecond >= 1
        ? '+${_trim(perSecond)}/s'
        : '+${_trim(perSecond * 60)}/min';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const GoldIcon(size: 18),
        const SizedBox(width: ConqueraSpace.sm),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: gold == null ? '--' : _thousands(gold!),
                style: ConqueraText.figure,
              ),
              if (rate != null)
                TextSpan(
                  text: '  ${_rateLabel(rate!)}',
                  style: ConqueraText.label,
                ),
            ],
          ),
        ),
      ],
    );
  }
}