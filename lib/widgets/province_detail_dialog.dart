import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';
import 'player_tag.dart';
import 'stat_block.dart';

/// The "Manage" window for one province.
///
/// Everyone sees the basic info. Only the owner also sees the Build and
/// Reinforce sections.
///
/// It reads the same live province/player data the map screen already
/// listens to (passed in as listenables), so numbers update the moment a
/// purchase goes through, and gold keeps ticking while the window is open.
class ProvinceDetailDialog extends StatefulWidget {
  final String gameId;
  final String uid;
  final String provinceId;
  final String provinceName;
  final ValueListenable<Map<String, ProvinceState>> provinceStates;
  final ValueListenable<Map<String, PlayerState>> players;
  final FirestoreService firestore;

  const ProvinceDetailDialog({
    super.key,
    required this.gameId,
    required this.uid,
    required this.provinceId,
    required this.provinceName,
    required this.provinceStates,
    required this.players,
    required this.firestore,
  });

  @override
  State<ProvinceDetailDialog> createState() => _ProvinceDetailDialogState();
}

class _ProvinceDetailDialogState extends State<ProvinceDetailDialog> {
  Timer? _ticker;

  /// Building picked in the dropdown but not built yet (null = none picked).
  /// Once the province actually has a building, that one is shown instead.
  BuildingDef? _pendingBuilding;

  /// Unit picked in the reinforce dropdown (null = none picked).
  UnitDef? _unit;

  bool _busy = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    // Re-evaluates "can I afford this?" as gold accumulates.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Time left until [readyAt] (zero if null or already past).
  Duration _remaining(DateTime? readyAt) {
    if (readyAt == null) return Duration.zero;
    final left = readyAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  String _clock(Duration d) {
    final secs = (d.inMilliseconds / 1000).ceil();
    return '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (!mounted) return;
      setState(() {
        _message = success;
        _isError = false;
      });
    } on GameActionException catch (e) {
      if (!mounted) return;
      setState(() {
        _message = e.message;
        _isError = true;
      });
    } catch (e) {
      debugPrint('Province action failed: $e');
      if (!mounted) return;
      setState(() {
        _message = 'Something went wrong. Try again.';
        _isError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _build() {
    final building = _pendingBuilding;
    if (building == null) return Future.value();
    return _run(
      () => widget.firestore.constructBuilding(
        gameId: widget.gameId,
        provinceId: widget.provinceId,
        uid: widget.uid,
        building: building,
      ),
      'Built ${building.name}.',
    );
  }

  Future<void> _destroy(String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: ConqueraColors.divider),
        ),
        title: Text('Destroy $label?', style: ConqueraText.name),
        content: Text(
          'The building is lost and you get no gold back.',
          style: ConqueraText.value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: ConqueraColors.danger,
            ),
            child: const Text('Destroy'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(() async {
      await widget.firestore.destroyBuilding(
        gameId: widget.gameId,
        provinceId: widget.provinceId,
        uid: widget.uid,
      );
      if (mounted) setState(() => _pendingBuilding = null);
    }, '$label destroyed.');
  }

  Future<void> _recruit() {
    final unit = _unit;
    if (unit == null) return Future.value();
    return _run(() async {
      await widget.firestore.recruitTroops(
        gameId: widget.gameId,
        provinceId: widget.provinceId,
        uid: widget.uid,
        unit: unit,
      );
      // Back to "Select unit" (and the price line below disappears).
      if (mounted) setState(() => _unit = null);
    }, '${unit.name} added: +${unit.power} power.');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: ConqueraColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(ConqueraSpace.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: ConqueraColors.divider),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.provinceStates, widget.players]),
          builder: (context, _) => _buildContent(context),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final province = widget.provinceStates.value[widget.provinceId];
    final players = widget.players.value;

    final ownerId = province?.ownerId;
    final owner = ownerId == null ? null : players[ownerId];
    final ownedByMe = ownerId != null && ownerId == widget.uid;

    final gold = players[widget.uid]?.goldAt(DateTime.now()) ?? 0;
    final troops = (province?.troops ?? 0).floor();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(ConqueraSpace.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.provinceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.title,
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Close',
                icon: const Icon(Icons.close, size: 20),
                color: ConqueraColors.muted,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: ConqueraSpace.sm),

          // Basic info (everyone)
          Wrap(
            spacing: ConqueraSpace.xl,
            runSpacing: ConqueraSpace.md,
            children: [
              StatBlock(
                label: 'Owner',
                child: PlayerTag(
                  name: owner?.displayName ??
                      (ownerId != null ? 'Unknown player' : 'Unclaimed'),
                  color: owner?.color,
                  style: ownerId == null
                      ? ConqueraText.value.copyWith(color: ConqueraColors.muted)
                      : ConqueraText.value,
                ),
              ),
              StatBlock(
                label: 'Power',
                child: Text('$troops', style: ConqueraText.value),
              ),
              StatBlock(
                label: 'Building',
                child: Text(
                  province?.buildingLabel ?? 'None',
                  style: ConqueraText.value,
                ),
              ),
            ],
          ),

          // Owner-only sections
          if (ownedByMe) ...[
            const SizedBox(height: ConqueraSpace.lg),
            const Divider(height: 1, color: ConqueraColors.divider),
            const SizedBox(height: ConqueraSpace.lg),
            const _SectionTitle('Build'),
            const SizedBox(height: ConqueraSpace.sm),
            ..._buildSection(
              province: province,
              gold: gold,
              buildReadyAt: players[widget.uid]?.buildReadyAt,
            ),
            const SizedBox(height: ConqueraSpace.lg),
            const Divider(height: 1, color: ConqueraColors.divider),
            const SizedBox(height: ConqueraSpace.lg),
            const _SectionTitle('Reinforce'),
            const SizedBox(height: ConqueraSpace.sm),
            ..._reinforceSection(troops: troops, gold: gold),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: ConqueraSpace.md),
                child: Text(
                  _message!,
                  style: ConqueraText.label.copyWith(
                    color:
                        _isError ? ConqueraColors.danger : ConqueraColors.ink,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Build section. Two states:
  ///  * province has a building: it is shown solid with a Destroy button;
  ///  * otherwise: a dropdown. Picking an entry only previews it (dashed
  ///    border, faded icon) until the Build button is pressed.
  List<Widget> _buildSection({
    required ProvinceState? province,
    required double gold,
    required DateTime? buildReadyAt,
  }) {
    if (province != null && province.hasBuilding) {
      final def = GameRules.buildingById(province.buildingType);
      return [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _IconSlot(icon: def?.icon ?? Icons.apartment),
            const SizedBox(width: ConqueraSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LockedField(text: province.buildingLabel),
                  const SizedBox(height: ConqueraSpace.sm),
                  _ActionRow(
                    info: def?.effectLabel ?? '',
                    unaffordable: false,
                    button: FilledButton(
                      onPressed:
                          _busy ? null : () => _destroy(province.buildingLabel),
                      style: FilledButton.styleFrom(
                        backgroundColor: ConqueraColors.danger,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            ConqueraColors.divider.withAlpha(90),
                      ),
                      child: const Text('Destroy'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ];
    }

    final pending = _pendingBuilding;
    final unaffordable = pending != null && gold < pending.cost;
    // After destroying a building the player must wait before building.
    final cooldownLeft = _remaining(buildReadyAt);
    final cooling = cooldownLeft > Duration.zero;
    final canBuild = pending != null && !unaffordable && !_busy && !cooling;

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconSlot(icon: pending?.icon, preview: pending != null),
          const SizedBox(width: ConqueraSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Dropdown<BuildingDef>(
                  value: pending,
                  hint: 'Select building',
                  items: GameRules.buildings,
                  label: (b) => '${b.name}  ·  ${b.cost} gold',
                  isEnabled: (b) => gold >= b.cost,
                  onChanged: _busy
                      ? null
                      : (b) => setState(() => _pendingBuilding = b),
                ),
                const SizedBox(height: ConqueraSpace.sm),
                _ActionRow(
                  info: pending == null
                      ? (cooling ? 'Cooling down after destroying a building' : '')
                      : '${pending.cost} gold  ·  ${pending.effectLabel}',
                  unaffordable: unaffordable,
                  button: FilledButton(
                    onPressed: canBuild ? _build : null,
                    child: Text(cooling ? 'Build ${_clock(cooldownLeft)}' : 'Build'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _reinforceSection({required int troops, required double gold}) {
    final unit = _unit;
    final unaffordable = unit != null && gold < unit.cost;
    final canRecruit = unit != null && !unaffordable && !_busy;

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('$troops', style: ConqueraText.figure),
          const SizedBox(width: ConqueraSpace.sm),
          Text('power', style: ConqueraText.label),
        ],
      ),
      const SizedBox(height: ConqueraSpace.sm),
      _Dropdown<UnitDef>(
        value: unit,
        hint: 'Select unit',
        items: GameRules.units,
        label: (u) => '${u.name}  ·  ${u.cost} gold',
        isEnabled: (u) => gold >= u.cost,
        onChanged: _busy ? null : (u) => setState(() => _unit = u),
      ),
      const SizedBox(height: ConqueraSpace.sm),
      _ActionRow(
        info: unit == null ? '' : '${unit.cost} gold  ·  +${unit.power} power',
        unaffordable: unaffordable,
        button: FilledButton(
          onPressed: canRecruit ? _recruit : null,
          child: const Text('Reinforce'),
        ),
      ),
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: ConqueraText.label.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
      ),
    );
  }
}

/// The square that shows a building's icon. Three looks:
///  * empty: a thin outline with a plus;
///  * [preview]: dashed blue outline and a faded black icon (picked, not
///    built yet);
///  * built: solid outline, white fill, black icon.
class _IconSlot extends StatelessWidget {
  final IconData? icon;
  final bool preview;

  const _IconSlot({required this.icon, this.preview = false});

  @override
  Widget build(BuildContext context) {
    final empty = icon == null;

    final box = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color:
            empty || preview ? Colors.transparent : Colors.white.withAlpha(170),
        borderRadius: BorderRadius.circular(6),
        border: preview ? null : Border.all(color: ConqueraColors.divider),
      ),
      child: Icon(
        icon ?? Icons.add,
        size: empty ? 20 : 28,
        color: empty
            ? ConqueraColors.divider
            : preview
                ? Colors.black.withAlpha(110)
                : Colors.black,
      ),
    );

    if (!preview) return box;
    return CustomPaint(
      foregroundPainter: const _DashedBorderPainter(
        color: ConqueraColors.accent,
        radius: 6,
      ),
      child: box,
    );
  }
}

/// Dashed rounded-rectangle outline, used to mark "not saved yet".
class _DashedBorderPainter extends CustomPainter {
  final Color color;
  final double radius;

  const _DashedBorderPainter({required this.color, required this.radius});

  static const double _dash = 5;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    ).deflate(0.75);
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + _dash), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// Same look as the dropdown, but not editable. Shows the building that is
/// already on the province.
class _LockedField extends StatelessWidget {
  final String text;

  const _LockedField({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(110),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConqueraText.value,
            ),
          ),
          const Icon(Icons.lock_outline, size: 16, color: ConqueraColors.muted),
        ],
      ),
    );
  }
}

/// Price / effect text on the left, action button on the right.
class _ActionRow extends StatelessWidget {
  final String info;
  final bool unaffordable;
  final Widget button;

  const _ActionRow({
    required this.info,
    required this.unaffordable,
    required this.button,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: info.isEmpty
              ? const SizedBox.shrink()
              : Text(
                  unaffordable ? '$info  ·  not enough gold' : info,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.label.copyWith(
                    color: unaffordable
                        ? ConqueraColors.danger
                        : ConqueraColors.muted,
                  ),
                ),
        ),
        const SizedBox(width: ConqueraSpace.sm),
        button,
      ],
    );
  }
}

/// Dropdown styled to match the rest of the UI. Nothing is selected until
/// the player picks something ([value] null shows [hint]). Entries for
/// which [isEnabled] returns false are greyed out and can't be picked.
/// The whole dropdown is disabled when [onChanged] is null.
class _Dropdown<T> extends StatelessWidget {
  final T? value;
  final String hint;
  final List<T> items;
  final String Function(T) label;
  final bool Function(T)? isEnabled;
  final ValueChanged<T?>? onChanged;

  const _Dropdown({
    required this.value,
    required this.hint,
    required this.items,
    required this.label,
    required this.onChanged,
    this.isEnabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(onChanged == null ? 70 : 170),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          onChanged: onChanged,
          hint: Text(
            hint,
            style: ConqueraText.value.copyWith(color: ConqueraColors.muted),
          ),
          icon: const Icon(Icons.expand_more, color: ConqueraColors.muted),
          style: ConqueraText.value,
          dropdownColor: ConqueraColors.surface,
          borderRadius: BorderRadius.circular(6),
          // The closed field always shows the pick in normal ink, even if
          // gold has since dropped and the entry is greyed in the list.
          selectedItemBuilder: (context) => [
            for (final item in items)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  label(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.value,
                ),
              ),
          ],
          items: [
            for (final item in items)
              _menuItem(item, enabled: isEnabled?.call(item) ?? true),
          ],
        ),
      ),
    );
  }

  DropdownMenuItem<T> _menuItem(T item, {required bool enabled}) {
    return DropdownMenuItem<T>(
      value: item,
      enabled: enabled,
      child: Text(
        label(item),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: enabled
            ? ConqueraText.value
            : ConqueraText.value.copyWith(
                color: ConqueraColors.muted.withAlpha(110),
              ),
      ),
    );
  }
}