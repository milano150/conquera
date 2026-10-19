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

/// Where the player's gold comes from: the total rate, a split by source
/// (territory tax and each kind of building), and every territory ranked
/// by what it earns. Everything is derived from the live world data.
/// This screen's own green palette (the rest of the game is blue-ish).
class _G {
  const _G._();

  static Color _p(Color light, Color dark, Color neon) => ConqueraColors.neon
      ? neon
      : (ConqueraColors.dark ? dark : light);

  static Color get bg =>
      _p(const Color(0xFFEDF5EE), const Color(0xFF0E1712), const Color(0xFF08120C));
  static Color get surface =>
      _p(const Color(0xFFE0EEE3), const Color(0xFF111C16), const Color(0xFF0A150F));
  static Color get divider =>
      _p(const Color(0xFFA3C9AD), const Color(0xFF2C4036), const Color(0xFF1F5A3C));
  static Color get ink =>
      _p(const Color(0xFF123A22), const Color(0xFFE3F1E7), const Color(0xFFE6FFEF));
  static Color get muted =>
      _p(const Color(0xFF4F7059), const Color(0xFF8AA595), const Color(0xFF6FAB87));
  static Color get accent =>
      _p(const Color(0xFF2E8B57), const Color(0xFF4FD18B), const Color(0xFF39FF9C));

  static TextStyle get value => ConqueraText.value.copyWith(color: ink);
  static TextStyle get label => ConqueraText.label.copyWith(color: muted);
  static TextStyle get figure => ConqueraText.figure.copyWith(color: ink);
  static TextStyle get title => ConqueraText.title.copyWith(color: ink);
}

class IncomeScreen extends StatefulWidget {
  final String uid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;

  /// province id -> country name.
  final Map<String, String> provinceNames;

  /// Ids of the provinces bordering a province (sea links included); a
  /// market earns for each of these the player also owns.
  final Set<String> Function(String id) neighborsOf;

  const IncomeScreen({
    super.key,
    required this.uid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.neighborsOf,
  });

  @override
  State<IncomeScreen> createState() => _IncomeScreenState();
}

/// One territory's earnings, per second.
class _Earning {
  final String id;
  final String name;
  final double tax;
  final BuildingDef? building;
  final double buildingIncome;
  final int partners;

  const _Earning({
    required this.id,
    required this.name,
    required this.tax,
    required this.building,
    required this.buildingIncome,
    required this.partners,
  });

  double get total => tax + buildingIncome;
}

/// One slice of the income split.
class _Source {
  final String name;
  final IconData icon;
  final Color color;
  final int count;
  double perSec;

  _Source({
    required this.name,
    required this.icon,
    required this.color,
    required this.count,
    required this.perSec,
  });
}

class _IncomeScreenState extends State<IncomeScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
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

  /// Up to 4 decimal places, no rounding beyond that, trailing zeros
  /// trimmed: 1,234.5 / 5.4 / 0.0005.
  static String _amount(double v) {
    var t = v.toStringAsFixed(4);
    t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    final parts = t.split('.');
    final whole = _thousands(int.parse(parts[0]));
    return parts.length == 2 ? '$whole.${parts[1]}' : whole;
  }

  static const List<double> _hues = [
    145, 95, 170, 120, 75, 158, 105, 135, 85, 165,
  ];

  static Color _sourceColor(int i) => HSLColor.fromAHSL(
        1,
        _hues[i % _hues.length],
        0.55,
        ConqueraColors.dark ? 0.55 : 0.4,
      ).toColor();

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _G.bg,
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
                    color: _G.ink,
                  ),
                  Text(
                    'Income',
                    style: _G.title.copyWith(fontSize: 22),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: _G.divider),
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
    final me = widget.players.value[widget.uid];
    if (me == null) return const SizedBox.shrink();

    final all = widget.provinces.value;
    final mine = all.values.where((p) => p.ownerId == widget.uid).toList();

    // Per-territory earnings.
    final earnings = <_Earning>[];
    for (final p in mine) {
      final def = p.hasBuilding ? GameRules.buildingById(p.buildingType) : null;
      final partners = widget
          .neighborsOf(p.id)
          .where((n) => all[n]?.ownerId == widget.uid)
          .length;
      earnings.add(_Earning(
        id: p.id,
        name: widget.provinceNames[p.id] ?? p.id,
        tax: GameRules.goldPerTerritoryPerSec,
        building: def,
        buildingIncome: def?.incomeFor(partners, p.id) ?? 0,
        partners: partners,
      ));
    }
    earnings.sort((a, b) {
      final c = b.total.compareTo(a.total);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

    // Split by source: tax first, then each income-making building type.
    final taxTotal = earnings.fold<double>(0, (s, e) => s + e.tax);
    final sources = <_Source>[
      _Source(
        name: 'Territory tax',
        icon: Icons.account_balance_outlined,
        color: _sourceColor(0),
        count: earnings.length,
        perSec: taxTotal,
      ),
    ];
    final byType = <String, _Source>{};
    for (final e in earnings) {
      final def = e.building;
      if (def == null || e.buildingIncome <= 0) continue;
      final s = byType.putIfAbsent(
        def.id,
        () => _Source(
          name: def.name,
          icon: def.icon,
          color: _sourceColor(byType.length + 1),
          count: 0,
          perSec: 0,
        ),
      );
      byType[def.id] = _Source(
        name: s.name,
        icon: s.icon,
        color: s.color,
        count: s.count + 1,
        perSec: s.perSec + e.buildingIncome,
      );
    }
    sources.addAll(byType.values);
    sources.sort((a, b) => b.perSec.compareTo(a.perSec));

    final sum = sources.fold<double>(0, (s, x) => s + x.perSec);
    final perSec = me.goldRate > 0 ? me.goldRate : sum;
    final perHour = perSec * 3600;
    final land = earnings.length;
    final best = earnings.isEmpty ? null : earnings.first;
    final maxTotal = best?.total ?? 1;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          children: [
            _hero(perHour, perSec, me.goldAt(ServerClock.now())),
            const SizedBox(height: ConqueraSpace.md),
            _card(
              title: 'SOURCES',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _splitBar(sources, sum),
                  const SizedBox(height: 8),
                  for (var i = 0; i < sources.length; i++)
                    _sourceRow(sources[i], sum, last: i == sources.length - 1),
                ],
              ),
            ),
            const SizedBox(height: ConqueraSpace.sm + 2),
            _card(
              title: 'TERRITORIES BY INCOME',
              trailing: Text('$land', style: _G.label),
              child: Column(
                children: [
                  for (var i = 0; i < earnings.length; i++)
                    _territoryRow(
                      i + 1,
                      earnings[i],
                      maxTotal,
                      last: i == earnings.length - 1,
                    ),
                ],
              ),
            ),
            const SizedBox(height: ConqueraSpace.lg),
          ],
        ),
      ),
    );
  }

  // --- Pieces --------------------------------------------------------------

  Widget _hero(double perHour, double perSec, double gold) {
    final big = _G.figure.copyWith(fontSize: 44, height: 1.0);
    return _box(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'INCOME RATE',
            style: _G.label.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const GoldIcon(size: 32),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  '+${_amount(perHour)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: big,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Text('/ hour', style: _G.label),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill(Text('${_amount(perSec * 86400)} / day', style: _pillStyle)),
              _pill(Text('${_amount(perSec * 60)} / min', style: _pillStyle)),
              _pill(Text('${_amount(perSec)} / sec', style: _pillStyle)),
              _pill(
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const GoldIcon(size: 15),
                    const SizedBox(width: 6),
                    Text(_amount(gold), style: _pillStyle),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  TextStyle get _pillStyle => _G.value.copyWith(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  Widget _pill(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _G.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _G.divider),
      ),
      child: child,
    );
  }

  Widget _splitBar(List<_Source> sources, double sum) {
    if (sum <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 12,
        child: Row(
          children: [
            for (final s in sources)
              if (s.perSec > 0)
                Expanded(
                  flex: (s.perSec / sum * 1000).round().clamp(1, 1000),
                  child: ColoredBox(color: s.color),
                ),
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(_Source s, double sum, {bool last = false}) {
    final share = sum > 0 ? s.perSec / sum : 0.0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: _G.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: s.color,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Icon(s.icon, size: 16, color: _G.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.count > 1 ? '${s.name}  ×${s.count}' : s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _G.value,
                ),
              ),
              Text(
                '${_amount(s.perSec * 3600)}/hr',
                style: _G.value.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              SizedBox(
                width: 46,
                child: Text(
                  '${(share * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: _G.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _thinBar(share, s.color),
        ],
      ),
    );
  }

  Widget _thinBar(double fraction, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: _G.divider.withAlpha(140)),
            ),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0).toDouble(),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _territoryRow(int n, _Earning e, double max, {bool last = false}) {
    final def = e.building;
    final detail = StringBuffer('tax ${_amount(e.tax * 3600)}');
    if (def != null && e.buildingIncome > 0) {
      detail.write('  +  ${def.name.toLowerCase()} ${_amount(e.buildingIncome * 3600)}');
      if (def.tradesWithNeighbors) {
        detail.write(' (${e.partners} partner${e.partners == 1 ? '' : 's'})');
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: _G.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '$n',
                  style: _G.label.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (def != null && e.buildingIncome > 0) ...[
                Icon(def.icon, size: 16, color: _G.ink),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _G.value,
                ),
              ),
              Text(
                '${_amount(e.total * 3600)}/hr',
                style: _G.value.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Text(
              detail.toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _G.label.copyWith(fontSize: 11.5),
            ),
          ),
          const SizedBox(height: 7),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: _thinBar(max > 0 ? e.total / max : 0, _G.accent),
          ),
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
                  style: _G.label.copyWith(
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
        color: _G.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _G.divider),
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.all(14),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}