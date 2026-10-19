import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/country_data.dart';
import '../models/player_state.dart';
import '../models/province_state.dart';
import '../theme/conquera_theme.dart';
import 'player_tag.dart';

enum LeaderboardSort {
  power('Total power'),
  size('Country size'),
  victories('Victories'),
  kills('Kills');

  final String label;
  const LeaderboardSort(this.label);
}

class _Entry {
  final PlayerState player;
  final int power;
  final int area;

  const _Entry(this.player, this.power, this.area);
}

/// Every player in the world, ranked. Sorted by total power by default, or
/// by empire size (combined area of the countries they own), battles won
/// (victories) or players eliminated (kills).
class LeaderboardPanel extends StatefulWidget {
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final String? myUid;
  final VoidCallback onBack;

  const LeaderboardPanel({
    super.key,
    required this.players,
    required this.provinces,
    required this.myUid,
    required this.onBack,
  });

  @override
  State<LeaderboardPanel> createState() => _LeaderboardPanelState();
}

class _LeaderboardPanelState extends State<LeaderboardPanel> {
  LeaderboardSort _sort = LeaderboardSort.power;

  List<_Entry> _entries() {
    final power = <String, int>{};
    final ids = <String, List<String>>{};
    widget.provinces.value.forEach((id, state) {
      final owner = state.ownerId;
      if (owner == null) return;
      power[owner] = (power[owner] ?? 0) + state.troops.floor();
      (ids[owner] ??= []).add(id);
    });

    final entries = [
      for (final p in widget.players.value.values)
        _Entry(
          p,
          power[p.uid] ?? 0,
          CountryData.totalArea(ids[p.uid] ?? const []),
        ),
    ];

    int value(_Entry e) => switch (_sort) {
          LeaderboardSort.power => e.power,
          LeaderboardSort.size => e.area,
          LeaderboardSort.victories => e.player.victories,
          LeaderboardSort.kills => e.player.kills,
        };
    entries.sort((a, b) {
      final byValue = value(b).compareTo(value(a));
      return byValue != 0
          ? byValue
          : a.player.displayName.compareTo(b.player.displayName);
    });
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ConqueraSpace.sm,
            ConqueraSpace.sm,
            ConqueraSpace.md,
            0,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 20),
                color: ConqueraColors.ink,
                tooltip: 'Back',
              ),
              Text('Leaderboard', style: ConqueraText.title.copyWith(fontSize: 22)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            ConqueraSpace.md,
            ConqueraSpace.xs,
            ConqueraSpace.md,
            ConqueraSpace.sm,
          ),
          child: Row(
            children: [
              Text('Sort by', style: ConqueraText.label),
              const SizedBox(width: ConqueraSpace.sm),
              PopupMenuButton<LeaderboardSort>(
                initialValue: _sort,
                color: ConqueraColors.surface,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (_) => [
                  for (final s in LeaderboardSort.values)
                    PopupMenuItem(
                      value: s,
                      child: Text(s.label, style: ConqueraText.value),
                    ),
                ],
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _sort.label,
                      style: ConqueraText.value.copyWith(
                        fontWeight: FontWeight.w600,
                        color: ConqueraColors.accent,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: ConqueraColors.accent,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: ConqueraColors.divider),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.players, widget.provinces]),
            builder: (context, _) {
              final entries = _entries();
              if (entries.isEmpty) {
                return Center(
                  child: Text('No players yet', style: ConqueraText.label),
                );
              }
              return ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, i) => _Row(
                  rank: i + 1,
                  entry: entries[i],
                  sort: _sort,
                  isMe: entries[i].player.uid == widget.myUid,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final int rank;
  final _Entry entry;
  final LeaderboardSort sort;
  final bool isMe;

  const _Row({
    required this.rank,
    required this.entry,
    required this.sort,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final value = switch (sort) {
      LeaderboardSort.power => _group(entry.power),
      LeaderboardSort.size => _area(entry.area),
      LeaderboardSort.victories => _group(entry.player.victories),
      LeaderboardSort.kills => _group(entry.player.kills),
    };

    return Container(
      color: isMe ? ConqueraColors.ink.withAlpha(14) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: ConqueraSpace.md,
        vertical: 12,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              style: ConqueraText.label.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: PlayerTag(
              name: entry.player.displayName,
              color: entry.player.color,
              style: ConqueraText.value.copyWith(
                fontSize: 16,
                fontWeight: isMe ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: ConqueraSpace.sm),
          Text(
            value,
            style: ConqueraText.value.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _group(int v) => v.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (_) => ',',
      );

  static String _area(int km2) {
    if (km2 >= 1000000) return '${(km2 / 1000000).toStringAsFixed(1)}M km²';
    return '${_group(km2)} km²';
  }
}