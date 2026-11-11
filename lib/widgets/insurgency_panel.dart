import 'dart:async';

import 'package:flutter/material.dart';

import '../services/firestore_service.dart' show GameActionException;
import '../services/server_clock.dart';
import '../theme/conquera_theme.dart';
import 'player_tag.dart';
import 'stat_block.dart';

/// The insurgent's control panel, shown at the top of the map while hiding in
/// a territory: who the host is, a countdown to the overthrow, the overthrow
/// button (greyed until the countdown ends) and a build button while the
/// hideout has no building.
class InsurgencyPanel extends StatefulWidget {
  final String territoryName;
  final String? hostName;
  final Color? hostColor;

  /// When the overthrow unlocks (null = not known yet).
  final DateTime? readyAt;

  /// Label of the building in the hideout, or null if there is none.
  final String? buildingLabel;

  final Future<void> Function() onOverthrow;
  final VoidCallback onBuild;

  const InsurgencyPanel({
    super.key,
    required this.territoryName,
    required this.hostName,
    required this.hostColor,
    required this.readyAt,
    required this.buildingLabel,
    required this.onOverthrow,
    required this.onBuild,
  });

  @override
  State<InsurgencyPanel> createState() => _InsurgencyPanelState();
}

class _InsurgencyPanelState extends State<InsurgencyPanel> {
  Timer? _tick;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration? get _left {
    final at = widget.readyAt;
    if (at == null) return null;
    final d = at.difference(ServerClock.now());
    return d.isNegative ? Duration.zero : d;
  }

  String _format(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes.remainder(60))}:'
        '${two(d.inSeconds.remainder(60))}';
  }

  Future<void> _overthrow() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: ConqueraColors.divider),
        ),
        title: Text('Overthrow ${widget.hostName ?? 'the owner'}?',
            style: ConqueraText.name),
        content: Text(
          '${widget.territoryName} becomes yours. The owner is told who '
          'did it and it appears in the news.',
          style: ConqueraText.value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: OutlinedButton.styleFrom(
              foregroundColor: ConqueraColors.danger,
              side: BorderSide(color: ConqueraColors.danger),
            ),
            child: const Text('Overthrow'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onOverthrow();
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final left = _left;
    final ready = left != null && left == Duration.zero;
    final active = ready && !_busy;
    final hostColor = widget.hostColor;
    // Same surface, divider and spacing as the country info panel.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        border: Border(bottom: BorderSide(color: ConqueraColors.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ConqueraSpace.md,
          ConqueraSpace.sm,
          ConqueraSpace.md,
          ConqueraSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.territoryName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConqueraText.title,
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm),
                Icon(Icons.visibility_off,
                    size: 15, color: ConqueraColors.danger),
                const SizedBox(width: 6),
                Text(
                  'INSURGENT · HIDDEN',
                  style: ConqueraText.label.copyWith(
                    color: ConqueraColors.danger,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: ConqueraSpace.xl,
                    runSpacing: ConqueraSpace.md,
                    children: [
                      StatBlock(
                        label: 'Held by',
                        child: PlayerTag(
                          name: widget.hostName ?? 'Unknown player',
                          color: hostColor,
                          style: ConqueraText.value,
                        ),
                      ),
                      StatBlock(
                        label: 'Building',
                        child: Text(
                          widget.buildingLabel ?? 'None',
                          style: ConqueraText.value,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm),
                // The Build button goes away once there is a building.
                if (widget.buildingLabel == null) ...[
                  OutlinedButton(
                    onPressed: _busy ? null : widget.onBuild,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ConqueraColors.ink,
                      minimumSize: const Size(44, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Icon(Icons.construction, size: 20),
                  ),
                  const SizedBox(width: ConqueraSpace.sm),
                ],
                // Hollow red outline, like the Attack button.
                OutlinedButton(
                  onPressed: active ? _overthrow : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ConqueraColors.danger,
                    side: BorderSide(
                      color: active
                          ? ConqueraColors.danger
                          : ConqueraColors.divider,
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          left == null || ready
                              ? 'Overthrow'
                              : 'Overthrow ${_format(left)}',
                        ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: ConqueraSpace.sm),
              Text(
                _error!,
                style: ConqueraText.label.copyWith(
                  color: ConqueraColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
