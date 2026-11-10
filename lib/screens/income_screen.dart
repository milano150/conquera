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

/// Where the player's gold comes from: the income rate, a split by source,
/// the income buildings the player has built with the price of the next one
/// of each kind, and every territory ranked by what it earns. Everything is derived from the live world data.
///
/// No boxes: sections are separated by thin lines and white space.
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
  final double perSec;

  const _Source({
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

  // --- Styles --------------------------------------------------------------

  Color get _ink => ConqueraColors.ink;
  Color get _muted => ConqueraColors.muted;
  Color get _line => ConqueraColors.divider;
  Color get _accent => ConqueraColors.accent;

  TextStyle get _value => ConqueraText.value;
  TextStyle get _label => ConqueraText.label;

  TextStyle get _num => ConqueraText.value.copyWith(
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  TextStyle get _sectionTitle => ConqueraText.label.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
      );

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

  /// Up to 4 decimal places, trailing zeros trimmed: 1,234.5 / 5.4 / 0.0005.
  static String _amount(double v) {
    var t = v.toStringAsFixed(4);
    t = t.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    final parts = t.split('.');
    final whole = _thousands(int.parse(parts[0]));
    return parts.length == 2 ? '$whole.${parts[1]}' : whole;
  }

  static const List<double> _hues = [
    205, 35, 150, 280, 8, 175, 320, 60, 240, 100,
  ];

  static Color _sourceColor(int i) => HSLColor.fromAHSL(
        1,
        _hues[i % _hues.length],
        0.55,
        ConqueraColors.dark ? 0.58 : 0.42,
      ).toColor();

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
                    color: _ink,
                  ),
                  Text(
                    'Income',
                    style: ConqueraText.title.copyWith(fontSize: 22),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: _line),
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
          .where((n) =>
              all[n]?.ownerId == widget.uid &&
              (def?.countsAsPartner(all[n]?.buildingType ?? 'none') ?? true))
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

    // How many of each building the player owns.
    final ownedByType = <String, int>{};
    for (final p in mine) {
      if (p.hasBuilding) {
        ownedByType[p.buildingType] = (ownedByType[p.buildingType] ?? 0) + 1;
      }
    }
    final incomeOwned = mine
        .where((p) => GameRules.isIncomeBuilding(p.buildingType))
        .length;

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
      final s = byType[def.id];
      byType[def.id] = _Source(
        name: def.name,
        icon: def.icon,
        color: s?.color ?? _sourceColor(byType.length + 1),
        count: (s?.count ?? 0) + 1,
        perSec: (s?.perSec ?? 0) + e.buildingIncome,
      );
    }
    sources.addAll(byType.values);
    sources.sort((a, b) => b.perSec.compareTo(a.perSec));

    final sum = sources.fold<double>(0, (s, x) => s + x.perSec);
    final perSec = me.goldRate > 0 ? me.goldRate : sum;
    final land = earnings.length;
    final maxTotal = earnings.isEmpty ? 1.0 : earnings.first.total;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            ConqueraSpace.md,
            ConqueraSpace.md,
            ConqueraSpace.md,
            ConqueraSpace.xl,
          ),
          children: [
            _hero(perSec, me.goldAt(ServerClock.now())),
            _section(
              'SOURCES',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _splitBar(sources, sum),
                  const SizedBox(height: 14),
                  for (var i = 0; i < sources.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    _sourceRow(sources[i], sum),
                  ],
                ],
              ),
            ),
            _section(
              'INCOME BUILDINGS',
              trailing: Text('$incomeOwned owned', style: _label),
              child: _buildingList(ownedByType),
            ),
            _section(
              'TERRITORIES BY INCOME',
              trailing: Text('$land', style: _label),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < earnings.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    _territoryRow(i + 1, earnings[i], maxTotal),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Pieces --------------------------------------------------------------

  /// A titled block separated from the previous one by a thin line.
  Widget _section(String title, {Widget? trailing, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: ConqueraSpace.lg),
        Divider(height: 1, color: _line),
        const SizedBox(height: ConqueraSpace.md),
        Row(
          children: [
            Expanded(child: Text(title, style: _sectionTitle)),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    );
  }

  Widget _hero(double perSec, double gold) {
    final big = ConqueraText.figure.copyWith(fontSize: 46, height: 1.0);
    final stats = <(String, String)>[
      ('PER DAY', _amount(perSec * 86400)),
      ('PER MIN', _amount(perSec * 60)),
      ('PER SEC', _amount(perSec)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('INCOME RATE', style: _sectionTitle),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const GoldIcon(size: 32),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '+${_amount(perSec * 3600)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: big,
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Text('/ hour', style: _label),
            ),
          ],
        ),
        const SizedBox(height: ConqueraSpace.md),
        Row(
          children: [
            for (final s in stats)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.$1, style: _label.copyWith(fontSize: 10.5)),
                    const SizedBox(height: 3),
                    Text(s.$2, style: _num),
                  ],
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('IN BANK', style: _label.copyWith(fontSize: 10.5)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const GoldIcon(size: 14),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          _amount(gold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _num,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
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

  Widget _sourceRow(_Source s, double sum) {
    final share = sum > 0 ? s.perSec / sum : 0.0;
    return Column(
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
            Icon(s.icon, size: 16, color: _muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.count > 1 ? '${s.name}  ×${s.count}' : s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _value,
              ),
            ),
            Text('${_amount(s.perSec * 3600)}/hr', style: _num),
            SizedBox(
              width: 46,
              child: Text(
                '${(share * 100).round()}%',
                textAlign: TextAlign.right,
                style: _label,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        _thinBar(share, s.color),
      ],
    );
  }

  Widget _thinBar(double fraction, Color color) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: _line.withAlpha(110))),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0).toDouble(),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }

  // --- Income buildings ----------------------------------------------------

  Widget _buildingList(Map<String, int> ownedByType) {
    // Only kinds the player has built.
    final defs = [
      for (final b in GameRules.buildings)
        if ((b.goldPerSec > 0 || b.goldPerPartnerPerSec > 0) &&
            (ownedByType[b.id] ?? 0) > 0)
          b,
    ];
    if (defs.isEmpty) {
      return Text('No income buildings yet.', style: _label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < defs.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          _buildingRow(defs[i], ownedByType[defs[i].id]!),
        ],
        const SizedBox(height: 14),
        Text(
          'The price shown is for the next one of that kind.',
          style: _label.copyWith(fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _buildingRow(BuildingDef def, int owned) {
    final price = GameRules.buildCostFor(def, owned);
    final detail = 'Owned $owned';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(def.icon, size: 16, color: _ink),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                def.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _value,
              ),
            ),
            Text('Next ', style: _label),
            GoldAmount(price, style: _num),
          ],
        ),
        const SizedBox(height: 3),
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _label.copyWith(fontSize: 11.5),
          ),
        ),
      ],
    );
  }

  // --- Territories ---------------------------------------------------------

  Widget _territoryRow(int n, _Earning e, double max) {
    final def = e.building;
    final detail = StringBuffer('tax ${_amount(e.tax * 3600)}');
    if (def != null && e.buildingIncome > 0) {
      detail.write(
          '  +  ${def.name.toLowerCase()} ${_amount(e.buildingIncome * 3600)}');
      if (def.suppliedBy.isNotEmpty) {
        detail.write(' (${e.partners} rig${e.partners == 1 ? '' : 's'})');
      } else if (def.tradesWithNeighbors) {
        detail.write(' (${e.partners} partner${e.partners == 1 ? '' : 's'})');
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '$n',
                style: _label.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (def != null && e.buildingIncome > 0) ...[
              Icon(def.icon, size: 16, color: _ink),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                e.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _value,
              ),
            ),
            Text('${_amount(e.total * 3600)}/hr', style: _num),
          ],
        ),
        const SizedBox(height: 5),
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: Text(
            detail.toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _label.copyWith(fontSize: 11.5),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 26),
          child: _thinBar(max > 0 ? e.total / max : 0, _accent),
        ),
      ],
    );
  }
}