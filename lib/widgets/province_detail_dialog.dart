import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../services/firestore_service.dart';
import '../services/server_clock.dart';
import '../theme/conquera_theme.dart';
import 'gold_amount.dart';
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
/// Reinforcing prices: gold per point of power.
const int _landGoldPerPower = 2;
const int _navyGoldPerPower = 5;

/// Most land power that can be bought in one go.
const int _maxLandPerPurchase = 1000;

class ProvinceDetailDialog extends StatefulWidget {
  final String gameId;
  final String uid;
  final String provinceId;
  final String provinceName;

  /// Ids of the provinces bordering this one (sea links included). A market
  /// earns for the ones the player owns, and is hidden if there are none.
  final Set<String> neighborIds;

  /// True if a radar lets the player see this province's power and building.
  final bool canSee;

  /// Like [canSee], but mines stay hidden from everyone but their owner.
  final bool canSeeBuilding;
  final ValueListenable<Map<String, ProvinceState>> provinceStates;
  final ValueListenable<Map<String, PlayerState>> players;
  final FirestoreService firestore;

  const ProvinceDetailDialog({
    super.key,
    required this.gameId,
    required this.uid,
    required this.provinceId,
    required this.provinceName,
    required this.neighborIds,
    this.canSee = false,
    this.canSeeBuilding = false,
    required this.provinceStates,
    required this.players,
    required this.firestore,
  });

  @override
  State<ProvinceDetailDialog> createState() => _ProvinceDetailDialogState();
}

class _ProvinceDetailDialogState extends State<ProvinceDetailDialog> {
  Timer? _ticker;

  /// Building picked in the picker but not built yet (null = none picked).
  /// Once the province actually has a building, that one is shown instead.
  BuildingDef? _pendingBuilding;

  /// Land power chosen on the reinforce slider.
  int _power = 1;

  /// Navy power chosen on the navy slider of a naval base.
  int _navyPower = 1;

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
    final left = readyAt.difference(ServerClock.now());
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

  /// How many of each building type the player owns (each one makes the next
  /// of the same type pricier).
  Map<String, int> get _ownedByType {
    final counts = <String, int>{};
    for (final s in widget.provinceStates.value.values) {
      if (s.ownerId == widget.uid && s.hasBuilding) {
        counts[s.buildingType] = (counts[s.buildingType] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Opens the building picker and previews whatever is chosen.
  Future<void> _pickBuilding(double gold) async {
    final picked = await showDialog<BuildingDef>(
      context: context,
      builder: (_) => _BuildingPicker(
        provinceId: widget.provinceId,
        neighbors: widget.neighborIds.length,
        ownNeighborTypes: {
          for (final id in widget.neighborIds)
            if (widget.provinceStates.value[id]?.ownerId == widget.uid)
              widget.provinceStates.value[id]!.buildingType,
        },
        gold: gold,
        ownedByType: _ownedByType,
        selected: _pendingBuilding,
      ),
    );
    if (picked != null && mounted) setState(() => _pendingBuilding = picked);
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
        neighborIds: widget.neighborIds,
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
          side: BorderSide(color: ConqueraColors.divider),
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
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: OutlinedButton.styleFrom(
              foregroundColor: ConqueraColors.danger,
              side: BorderSide(color: ConqueraColors.danger),
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

  Future<void> _recruitNavy(int power) {
    if (power < 1) return Future.value();
    final unit = UnitDef(
      id: 'navy',
      name: 'Navy',
      power: power,
      cost: power * _navyGoldPerPower,
    );
    return _run(() async {
      await widget.firestore.recruitNavy(
        gameId: widget.gameId,
        provinceId: widget.provinceId,
        uid: widget.uid,
        unit: unit,
      );
      if (mounted) setState(() => _navyPower = 1);
    }, '+$power navy added.');
  }

  Future<void> _recruit(int power) {
    if (power < 1) return Future.value();
    final unit = UnitDef(
      id: 'reinforce',
      name: 'Reinforcement',
      power: power,
      cost: power * _landGoldPerPower,
    );
    return _run(() async {
      await widget.firestore.recruitTroops(
        gameId: widget.gameId,
        provinceId: widget.provinceId,
        uid: widget.uid,
        unit: unit,
      );
      if (mounted) setState(() => _power = 1);
    }, '+$power power added.');
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

    final gold = players[widget.uid]?.goldAt(ServerClock.now()) ?? 0;
    final troops = (province?.troops ?? 0).floor();

    // Bordering territories the player owns: what a market trades with.
    final states = widget.provinceStates.value;
    final partners = widget.neighborIds
        .where((id) => states[id]?.ownerId == widget.uid)
        .length;

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
                child: Text(ownedByMe || widget.canSee ? '$troops' : '?', style: ConqueraText.value),
              ),
              StatBlock(
                label: 'Building',
                child: Text(
                  ownedByMe || widget.canSeeBuilding
                      ? (province?.buildingLabel ?? 'None')
                      : '?',
                  style: ConqueraText.value,
                ),
              ),
            ],
          ),

          // Owner-only sections
          if (ownedByMe) ...[
            const SizedBox(height: ConqueraSpace.lg),
            Divider(height: 1, color: ConqueraColors.divider),
            const SizedBox(height: ConqueraSpace.lg),
            const _SectionTitle('Build'),
            const SizedBox(height: ConqueraSpace.sm),
            ..._buildSection(
              province: province,
              gold: gold,
              partners: partners,
              buildReadyAt: players[widget.uid]?.buildReadyAt,
            ),
            const SizedBox(height: ConqueraSpace.lg),
            Divider(height: 1, color: ConqueraColors.divider),
            const SizedBox(height: ConqueraSpace.lg),
            const _SectionTitle('Reinforce'),
            const SizedBox(height: ConqueraSpace.sm),
            ..._reinforceSection(
              troops: troops,
              gold: gold,
              navy: province?.isNavalBase == true ? province!.navy : null,
            ),
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

  /// Bordering territories of the player that count for [def]: all of them
  /// for a market, only the rigs and oil fields for a refinery.
  int _partnersFor(BuildingDef? def) => widget.neighborIds.where((id) {
        final s = widget.provinceStates.value[id];
        return s?.ownerId == widget.uid &&
            (def?.countsAsPartner(s?.buildingType ?? 'none') ?? true);
      }).length;

  /// Build section. Two states:
  ///  * province has a building: it is shown solid with a Destroy button;
  ///  * otherwise: a field that opens the building picker (buildings in
  ///    sections, three per row). Picking one only previews it (dashed
  ///    border, faded icon) until the Build button is pressed.
  List<Widget> _buildSection({
    required ProvinceState? province,
    required double gold,
    required int partners,
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
                    info: def?.effectLabelFor(_partnersFor(def), widget.provinceId) ?? '',
                    unaffordable: false,
                    button: OutlinedButton(
                      onPressed:
                          _busy ? null : () => _destroy(province.buildingLabel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ConqueraColors.danger,
                        side: BorderSide(
                          color: _busy
                              ? ConqueraColors.divider
                              : ConqueraColors.danger,
                        ),
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
    final pendingPrice = pending == null
        ? null
        : GameRules.buildCostFor(pending, _ownedByType[pending.id] ?? 0);
    final unaffordable = pendingPrice != null && gold < pendingPrice;
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
                _PickerField(
                  hint: 'Select building',
                  label: pending?.name,
                  price: pendingPrice,
                  onTap: _busy ? null : () => _pickBuilding(gold),
                ),
                const SizedBox(height: ConqueraSpace.sm),
                _ActionRow(
                  info: pending == null
                      ? (cooling ? 'Cooling down' : '')
                      : pending.effectLabelFor(_partnersFor(pending), widget.provinceId),
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

  List<Widget> _reinforceSection({
    required int troops,
    required double gold,
    double? navy,
  }) {
    // Land: 1 .. gold / 2, capped at 1000 power per purchase.
    final maxLand = math.min(gold ~/ _landGoldPerPower, _maxLandPerPurchase);
    final power = maxLand < 1 ? 0 : _power.clamp(1, maxLand).toInt();

    // Navy: 1 .. gold / 5, capped by the room left in the naval base.
    final navyRoom = navy == null ? 0 : (GameRules.maxNavy - navy).ceil();
    final maxNavy = math.min(gold ~/ _navyGoldPerPower, navyRoom);
    final navyPower = maxNavy < 1 ? 0 : _navyPower.clamp(1, maxNavy).toInt();

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
      _AmountSlider(
        value: power,
        max: maxLand,
        goldPerPower: _landGoldPerPower,
        unit: 'power',
        color: ConqueraColors.accent,
        onChanged: _busy ? null : (v) => setState(() => _power = v),
      ),
      const SizedBox(height: ConqueraSpace.sm),
      _ActionRow(
        info: '',
        unaffordable: maxLand < 1,
        button: FilledButton(
          onPressed: power >= 1 && !_busy ? () => _recruit(power) : null,
          child: const Text('Reinforce'),
        ),
      ),
      // A naval base also holds a navy (blue), bought separately.
      if (navy != null) ...[
        const SizedBox(height: ConqueraSpace.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '${navy.floor()}',
              style: ConqueraText.figure.copyWith(color: GameRules.navyColor),
            ),
            Text(
              ' / ${GameRules.maxNavy.floor()}',
              style: ConqueraText.label,
            ),
            const SizedBox(width: ConqueraSpace.sm),
            Text('navy', style: ConqueraText.label),
          ],
        ),
        const SizedBox(height: ConqueraSpace.sm),
        _AmountSlider(
          value: navyPower,
          max: maxNavy,
          goldPerPower: _navyGoldPerPower,
          unit: 'navy',
          color: GameRules.navyColor,
          onChanged: _busy ? null : (v) => setState(() => _navyPower = v),
        ),
        const SizedBox(height: ConqueraSpace.sm),
        _ActionRow(
          info: navyRoom < 1 ? 'Navy is full' : '',
          unaffordable: navyRoom >= 1 && maxNavy < 1,
          button: OutlinedButton(
            onPressed:
                navyPower >= 1 && !_busy ? () => _recruitNavy(navyPower) : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: GameRules.navyColor,
              side: BorderSide(
                color: navyPower >= 1 && !_busy
                    ? GameRules.navyColor
                    : ConqueraColors.divider,
              ),
            ),
            child: const Text('Add navy'),
          ),
        ),
      ],
    ];
  }
}

/// Amount picker for reinforcing: a big "+N" readout with its gold price,
/// then  [-]  slider  [+]  [MAX]  underneath. Picks 1..[max]; everything is
/// greyed out when [max] is below 1 (nothing affordable / no room).
class _AmountSlider extends StatelessWidget {
  final int value;
  final int max;
  final int goldPerPower;
  final String unit;
  final Color color;
  final ValueChanged<int>? onChanged;

  const _AmountSlider({
    required this.value,
    required this.max,
    required this.goldPerPower,
    required this.unit,
    required this.color,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = max >= 1 && onChanged != null;
    final accent = enabled ? color : ConqueraColors.muted.withAlpha(120);
    final readout = ConqueraText.figure.copyWith(
      fontSize: 26,
      color: accent,
    );

    void set(int v) => onChanged?.call(v.clamp(1, max).toInt());

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(enabled ? 130 : 60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled ? color.withAlpha(150) : ConqueraColors.divider,
        ),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(max < 1 ? '+0' : '+$value', style: readout),
              const SizedBox(width: 6),
              Text(unit, style: ConqueraText.label),
              const Spacer(),
              GoldAmount(
                max < 1 ? 0 : value * goldPerPower,
                style: ConqueraText.figure.copyWith(
                  color: enabled
                      ? ConqueraColors.ink
                      : ConqueraColors.muted.withAlpha(140),
                ),
                faded: !enabled,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _StepButton(
                icon: Icons.remove,
                color: color,
                onTap: enabled && value > 1 ? () => set(value - 1) : null,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 8,
                    activeTrackColor: accent,
                    inactiveTrackColor: ConqueraColors.divider.withAlpha(110),
                    disabledActiveTrackColor: accent,
                    disabledInactiveTrackColor:
                        ConqueraColors.divider.withAlpha(70),
                    overlayColor: color.withAlpha(36),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 20),
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                    thumbShape: _GameThumb(color: accent),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: max < 1 ? 0 : value.clamp(1, max).toDouble(),
                    min: max < 1 ? 0 : 1,
                    max: max < 2 ? 1 : max.toDouble(),
                    divisions: max > 1 ? max - 1 : null,
                    onChanged: enabled && max > 1 ? (v) => set(v.round()) : null,
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.add,
                color: color,
                onTap: enabled && value < max ? () => set(value + 1) : null,
              ),
              const SizedBox(width: 6),
              _StepButton(
                label: 'MAX',
                color: color,
                onTap: enabled && value < max ? () => set(max) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small squarish outlined (icon or label) button beside the slider.
class _StepButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final Color color;
  final VoidCallback? onTap;

  const _StepButton({
    this.icon,
    this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    // Matches the shared hollow buttons (Destroy / Reinforce): transparent,
    // 1px outline, 6px corners.
    final c = on ? ConqueraColors.ink : ConqueraColors.muted.withAlpha(150);
    final border = on ? ConqueraColors.ink : ConqueraColors.divider;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        constraints: const BoxConstraints(minWidth: 30),
        padding: EdgeInsets.symmetric(horizontal: label != null ? 10 : 0),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        child: icon != null
            ? Icon(icon, size: 16, color: c)
            : Text(
                label!,
                style: ConqueraText.label.copyWith(
                  color: c,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.8,
                ),
              ),
      ),
    );
  }
}

/// Round thumb: soft shadow, light fill, thick colored ring and a small
/// colored core, so it reads like a game dial rather than a stock slider.
class _GameThumb extends SliderComponentShape {
  final Color color;

  const _GameThumb({required this.color});

  static const double _r = 11;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_r);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final grow = 1 + 0.12 * activationAnimation.value;
    final r = _r * grow;

    canvas.drawCircle(
      center.translate(0, 1.5),
      r,
      Paint()
        ..color = Colors.black.withAlpha(50)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      r - 1.5,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(center, 3, Paint()..color = color);
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
      foregroundPainter: _DashedBorderPainter(
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
          Icon(Icons.lock_outline, size: 16, color: ConqueraColors.muted),
        ],
      ),
    );
  }
}

/// Price / effect text on the left, action button on the right. The price
/// is shown with the gold coin icon.
class _ActionRow extends StatelessWidget {
  final String info;
  final int? price;
  final bool unaffordable;
  final Widget button;

  const _ActionRow({
    required this.info,
    required this.unaffordable,
    required this.button,
    this.price,
  });

  @override
  Widget build(BuildContext context) {
    final style = ConqueraText.label.copyWith(
      color: unaffordable ? ConqueraColors.danger : ConqueraColors.muted,
    );

    final spans = <InlineSpan>[];
    void separator() {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '  ·  '));
    }

    if (price != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GoldAmount(price!, style: style, iconSize: 13),
        ),
      );
    }
    if (info.isNotEmpty) {
      separator();
      spans.add(TextSpan(text: info));
    }
    if (unaffordable) {
      separator();
      spans.add(const TextSpan(text: 'Not enough gold'));
    }

    return Row(
      children: [
        Expanded(
          child: spans.isEmpty
              ? const SizedBox.shrink()
              : Text.rich(
                  TextSpan(style: style, children: spans),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(width: ConqueraSpace.sm),
        button,
      ],
    );
  }
}

/// Same look as the dropdown it replaced, but tapping it opens the building
/// picker. Shows [hint] until something is chosen, then "name  ·  price".
class _PickerField extends StatelessWidget {
  final String hint;
  final String? label;
  final int? price;
  final VoidCallback? onTap;

  const _PickerField({
    required this.hint,
    required this.label,
    required this.price,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chosen = label != null;
    return Material(
      color: Colors.white.withAlpha(onTap == null ? 70 : 170),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: ConqueraColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: chosen
                    ? Row(
                        children: [
                          Flexible(
                            child: Text(
                              '$label  ·  ',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ConqueraText.value,
                            ),
                          ),
                          if (price != null)
                            GoldAmount(price!, style: ConqueraText.value),
                        ],
                      )
                    : Text(
                        hint,
                        style: ConqueraText.value
                            .copyWith(color: ConqueraColors.muted),
                      ),
              ),
              Icon(Icons.expand_more, color: ConqueraColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

enum _Category {
  production('Production'),
  surveillance('Surveillance'),
  defense('Defense'),
  military('Military');

  final String label;
  const _Category(this.label);
}

_Category _categoryOf(BuildingDef b) => switch (b.id) {
      'watchtower' || 'radar' || 'high_altitude_radar' => _Category.surveillance,
      'fortress' || 'wall' || 'mines' || 'dome' => _Category.defense,
      'barracks' || 'missile_silo' || 'naval_base' => _Category.military,
      _ => _Category.production,
    };

/// The "Select building" window: every building in sections, three per row.
/// Buildings the player can't afford are faded; ones this territory can't
/// hold are faded with the reason. Tapping an available one picks it and
/// closes the window.
class _BuildingPicker extends StatelessWidget {
  final String provinceId;
  final int neighbors;

  /// Building types on the bordering territories the player owns.
  final Set<String> ownNeighborTypes;
  final double gold;
  /// building id -> how many the player owns.
  final Map<String, int> ownedByType;
  final BuildingDef? selected;

  const _BuildingPicker({
    required this.provinceId,
    required this.neighbors,
    required this.ownNeighborTypes,
    required this.gold,
    required this.ownedByType,
    required this.selected,
  });

  /// Buildings this territory can't hold are not shown at all.
  /// A refinery also needs a bordering rig or oil field of the player.
  bool _available(BuildingDef b) =>
      GameRules.canBuildHere(b, provinceId, neighbors: neighbors) &&
      (b.suppliedBy.isEmpty || b.suppliedBy.any(ownNeighborTypes.contains));

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
              Row(
                children: [
                  Expanded(
                    child: Text('Select building', style: ConqueraText.title),
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
              for (final category in _Category.values)
                ..._section(context, category),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _section(BuildContext context, _Category category) {
    final items = [
      for (final b in GameRules.buildings)
        if (_categoryOf(b) == category && _available(b)) b,
    ];
    if (items.isEmpty) return const [];
    return [
      const SizedBox(height: ConqueraSpace.md),
      Divider(height: 1, color: ConqueraColors.divider),
      const SizedBox(height: ConqueraSpace.md),
      _SectionTitle(category.label),
      const SizedBox(height: ConqueraSpace.sm),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: ConqueraSpace.sm,
        crossAxisSpacing: ConqueraSpace.sm,
        childAspectRatio: 0.95,
        children: [
          for (final b in items)
            _BuildingTile(
              building: b,
              selected: selected?.id == b.id,
              price: GameRules.buildCostFor(b, ownedByType[b.id] ?? 0),
              owned: ownedByType[b.id] ?? 0,
              affordable:
                  gold >= GameRules.buildCostFor(b, ownedByType[b.id] ?? 0),
              onTap: () => Navigator.of(context).pop(b),
              onInfo: () => showDialog<void>(
                context: context,
                builder: (_) => _BuildingInfoDialog(
                  building: b,
                  provinceId: provinceId,
                  price: GameRules.buildCostFor(b, ownedByType[b.id] ?? 0),
                ),
              ),
            ),
        ],
      ),
    ];
  }
}

class _BuildingTile extends StatelessWidget {
  final BuildingDef building;
  final int price;
  final int owned;
  final bool selected;
  final bool affordable;
  final VoidCallback onTap;
  final VoidCallback onInfo;

  const _BuildingTile({
    required this.building,
    required this.price,
    required this.owned,
    required this.selected,
    required this.affordable,
    required this.onTap,
    required this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = affordable;
    return Stack(
      children: [
        Positioned.fill(child: _tile(enabled)),
        Positioned(
          top: 6,
          left: 6,
          child: GestureDetector(
            onTap: onInfo,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.info_outline,
                size: 14,
                color: ConqueraColors.muted,
              ),
            ),
          ),
        ),
        Positioned(
          top: 9,
          right: 8,
          child: Text(
            'Owned $owned',
            style: ConqueraText.label.copyWith(
              fontSize: 11,
              fontWeight: owned > 0 ? FontWeight.w700 : FontWeight.w400,
              color: owned > 0 ? ConqueraColors.ink : ConqueraColors.muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(bool enabled) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.white.withAlpha(170),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: selected ? ConqueraColors.accent : ConqueraColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(ConqueraSpace.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(building.icon, size: 30, color: Colors.black),
                const SizedBox(height: 6),
                Text(
                  building.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.value.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                GoldAmount(
                  price,
                  style: ConqueraText.label.copyWith(
                    color: affordable
                        ? ConqueraColors.muted
                        : ConqueraColors.danger,
                  ),
                  iconSize: 12,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Detail box opened by a tile's info icon.
class _BuildingInfoDialog extends StatelessWidget {
  final BuildingDef building;
  final String? provinceId;
  final int? price;

  const _BuildingInfoDialog({
    required this.building,
    this.provinceId,
    this.price,
  });

  String get _where => switch (building.site) {
        BuildSite.coastal => 'Coastal territories',
        BuildSite.archipelago => 'Island territories',
        BuildSite.mountainous => 'Mountainous territories',
        BuildSite.producer => switch (building.id) {
          'diamond_mine' => 'Diamond-mining territories',
          'uranium_mine' => 'Uranium-mining territories',
          'silver_mine' => 'Silver-mining territories',
          _ => 'Mainland oil producers',
        },
        BuildSite.anywhere =>
          building.tradesWithNeighbors ? 'Needs a neighbor' : 'Anywhere',
      };

  Widget _row(String label, Widget value) => Padding(
        padding: const EdgeInsets.only(top: ConqueraSpace.sm),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(label, style: ConqueraText.label),
            ),
            Expanded(child: value),
          ],
        ),
      );

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
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(building.icon, size: 26, color: Colors.black),
                  const SizedBox(width: ConqueraSpace.sm),
                  Expanded(
                    child: Text(building.name, style: ConqueraText.title),
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
              Text(building.details, style: ConqueraText.value),
              const SizedBox(height: ConqueraSpace.sm),
              Divider(height: 1, color: ConqueraColors.divider),
              _row(
                'Cost',
                GoldAmount(price ?? building.cost, style: ConqueraText.value),
              ),
              _row(
                'Effect',
                Text(building.effectLabelFor(0, provinceId), style: ConqueraText.value),
              ),
              _row('Where', Text(_where, style: ConqueraText.value)),
            ],
          ),
        ),
      ),
    );
  }
}