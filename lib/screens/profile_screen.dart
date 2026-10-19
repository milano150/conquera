import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../services/server_clock.dart';
import '../theme/conquera_theme.dart';
import '../widgets/gold_amount.dart';

/// A player's profile: avatar, name, rank and a set of live stats (land,
/// power, gold, buildings), all computed from the world data already on the
/// map screen, so it updates on its own.
class ProfileScreen extends StatefulWidget {
  final String uid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;

  /// province id -> country name.
  final Map<String, String> provinceNames;

  /// How many territories the world has in total.
  final int totalTerritories;

  const ProfileScreen({
    super.key,
    required this.uid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.totalTerritories,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Gold ticks up and cooldowns count down.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // --- Formatting ----------------------------------------------------------

  static String _thousands(num value) {
    final digits = value.floor().toString();
    final b = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
      b.write(digits[i]);
    }
    return b.toString();
  }

  // --- Build ---------------------------------------------------------------

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
                    'Profile',
                    style: ConqueraText.title.copyWith(fontSize: 22),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: ConqueraColors.divider),
            Expanded(
              child: ListenableBuilder(
                listenable:
                    Listenable.merge([widget.players, widget.provinces]),
                builder: (context, _) => _content(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final players = widget.players.value;
    final me = players[widget.uid];
    if (me == null) return const SizedBox.shrink();

    final now = ServerClock.now();
    final all = widget.provinces.value.values;
    final mine = all.where((p) => p.ownerId == widget.uid).toList()
      ..sort((a, b) => b.troops.compareTo(a.troops));

    final land = mine.length;
    final total = widget.totalTerritories;
    final share = total > 0 ? land / total : 0.0;
    final power = mine.fold<double>(0, (s, p) => s + p.troops);
    final gold = me.goldAt(now);

    final buildingCounts = <BuildingDef, int>{};
    for (final p in mine) {
      final def = GameRules.buildingById(p.buildingType);
      if (def != null && p.hasBuilding) {
        buildingCounts[def] = (buildingCounts[def] ?? 0) + 1;
      }
    }
    final buildingTotal =
        buildingCounts.values.fold<int>(0, (s, n) => s + n);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          children: [
            _hero(me),
            const SizedBox(height: ConqueraSpace.md),
            Row(
              children: [
                Expanded(
                  child: _tile(
                    icon: Icons.public,
                    label: 'TERRITORIES',
                    value: '$land',
                    sub: '${(share * 100).toStringAsFixed(share > 0 && share < 0.1 ? 1 : 0)}% of the world',
                    accent: me.color,
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm + 2),
                Expanded(
                  child: _tile(
                    icon: Icons.shield_outlined,
                    label: 'TOTAL POWER',
                    value: _thousands(power),
                    sub: land == 0
                        ? 'No land'
                        : '${_thousands(power / land)} avg per territory',
                    accent: ConqueraColors.danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.sm + 2),
            Row(
              children: [
                Expanded(
                  child: _tile(
                    icon: null,
                    goldIcon: true,
                    label: 'GOLD',
                    value: _thousands(gold),
                    sub: '+${_thousands(me.goldRate * 3600)} per hour',
                    accent: ConqueraColors.brass,
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm + 2),
                Expanded(
                  child: _tile(
                    icon: Icons.apartment,
                    label: 'BUILDINGS',
                    value: '$buildingTotal',
                    sub: land == 0
                        ? 'None'
                        : '${(buildingTotal / land * 100).round()}% of your land',
                    accent: ConqueraColors.accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.md),
            _card(
              title: 'WORLD SHARE',
              trailing: Text(
                '$land / $total',
                style: ConqueraText.label,
              ),
              child: _bar(share, me.color),
            ),
            if (buildingCounts.isNotEmpty) ...[
              const SizedBox(height: ConqueraSpace.sm + 2),
              _card(
                title: 'BUILDINGS',
                child: Wrap(
                  spacing: ConqueraSpace.sm,
                  runSpacing: ConqueraSpace.sm,
                  children: [
                    for (final e in buildingCounts.entries)
                      _chip(e.key.icon, e.key.name, e.value),
                  ],
                ),
              ),
            ],
            if (mine.isNotEmpty) ...[
              const SizedBox(height: ConqueraSpace.sm + 2),
              _card(
                title: 'TERRITORIES',
                trailing: Text('${mine.length}', style: ConqueraText.label),
                child: Column(
                  children: [
                    for (var i = 0; i < mine.length; i++)
                      _territoryRow(
                        i + 1,
                        mine[i],
                        me.color,
                        last: i == mine.length - 1,
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: ConqueraSpace.lg),
          ],
        ),
      ),
    );
  }

  // --- Pieces --------------------------------------------------------------

  Widget _hero(PlayerState me) {
    final color = me.color;
    final initial =
        me.displayName.isEmpty ? '?' : me.displayName.characters.first.toUpperCase();
    return _box(
      padding: const EdgeInsets.symmetric(
        horizontal: ConqueraSpace.md,
        vertical: ConqueraSpace.lg,
      ),
      child: Column(
        children: [
          // Avatar: a rounded square in the player's color with a soft ring.
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: color.withAlpha(90), width: 2),
            ),
            child: Container(
              width: 88,
              height: 88,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(color, Colors.white, 0.18)!,
                    Color.lerp(color, ConqueraColors.ink, 0.25)!,
                  ],
                ),
              ),
              child: Text(
                initial,
                style: ConqueraText.title.copyWith(
                  fontSize: 42,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: ConqueraSpace.md),
          Text(
            me.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.title.copyWith(fontSize: 26),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData? icon,
    bool goldIcon = false,
    required String label,
    required String value,
    required String sub,
    required Color accent,
  }) {
    return _box(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: goldIcon
                    ? const GoldIcon(size: 16)
                    : Icon(icon, size: 17, color: accent),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.label.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.figure.copyWith(fontSize: 30),
          ),
          const SizedBox(height: 2),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: ConqueraText.label),
        ],
      ),
    );
  }

  Widget _card({
    required String title,
    Widget? trailing,
    required Widget child,
  }) {
    return _box(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: ConqueraText.label.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _box({required Widget child, EdgeInsets? padding}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(14),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  Widget _bar(double fraction, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 10,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: ConqueraColors.divider.withAlpha(140)),
            ),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0).toDouble(),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color,
                      Color.lerp(color, Colors.white, 0.3)!,
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String name, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ConqueraColors.land,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: ConqueraColors.ink),
          const SizedBox(width: 6),
          Text(name, style: ConqueraText.value.copyWith(fontSize: 13)),
          const SizedBox(width: 8),
          Text(
            '×$count',
            style: ConqueraText.value.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: ConqueraColors.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _territoryRow(int n, ProvinceState p, Color color, {bool last = false}) {
    final def = p.hasBuilding ? GameRules.buildingById(p.buildingType) : null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: ConqueraColors.divider)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$n',
              style: ConqueraText.label.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.provinceNames[p.id] ?? p.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConqueraText.value,
            ),
          ),
          if (def != null) ...[
            Icon(def.icon, size: 16, color: ConqueraColors.muted),
            const SizedBox(width: 10),
          ],
          Text(
            _thousands(p.troops),
            style: ConqueraText.value.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}