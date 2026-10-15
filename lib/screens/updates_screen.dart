import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/update_entry.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';

/// The player's war log, laid out like a chat: oldest at the top, newest at
/// the bottom, new entries appearing below as they happen.
///
///  * A war shows as "War of {territory}": red when it was an attack on
///    you, green when you were the attacker. Tap it to see every territory
///    involved and its troops.
///  * A building you built is a blue card, one you destroyed a grey card.
class UpdatesScreen extends StatefulWidget {
  final String gameId;
  final String uid;
  final FirestoreService firestore;

  /// province id -> country name.
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, PlayerState>> players;

  const UpdatesScreen({
    super.key,
    required this.gameId,
    required this.uid,
    required this.firestore,
    required this.provinceNames,
    required this.players,
  });

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<List<UpdateEntry>>? _sub;
  List<UpdateEntry> _entries = const [];
  bool _loaded = false;
  final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    _sub = widget.firestore
        .watchUpdates(gameId: widget.gameId, uid: widget.uid)
        .listen(
      (list) {
        if (!mounted) return;
        // Stay glued to the bottom unless the player scrolled up to read.
        final stick = !_scroll.hasClients ||
            _scroll.position.maxScrollExtent - _scroll.offset < 140;
        setState(() {
          _entries = list;
          _loaded = true;
        });
        if (stick) _toBottom();
      },
      onError: (Object e) => debugPrint('Updates stream error: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String _province(String id) => widget.provinceNames[id] ?? id;

  String _player(String? id) =>
      (id == null ? null : widget.players.value[id]?.displayName) ?? 'Unknown';

  /// A player's color, darkened a little so it reads on the pale cards.
  Color _playerColor(String? id) {
    final base = id == null ? null : widget.players.value[id]?.color;
    return base == null
        ? ConqueraColors.ink
        : Color.lerp(base, ConqueraColors.ink, 0.25)!;
  }

  String _building(String id) => GameRules.buildingById(id)?.name ?? id;

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
                  Text('Updates', style: ConqueraText.title.copyWith(fontSize: 22)),
                ],
              ),
            ),
            const Divider(height: 1, color: ConqueraColors.divider),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (!_loaded) return const SizedBox.shrink();
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ConqueraSpace.lg),
          child: Text(
            'Nothing yet. Attacks, new buildings and demolitions will show up here.',
            textAlign: TextAlign.center,
            style: ConqueraText.label.copyWith(fontSize: 14),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(ConqueraSpace.md),
      itemCount: _entries.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: ConqueraSpace.sm),
        child: _card(_entries[i]),
      ),
    );
  }

  Widget _card(UpdateEntry e) {
    switch (e.type) {
      case UpdateType.build:
        return _simple(
          e,
          ConqueraColors.accent,
          '${_building(e.buildingId)} built in ${_province(e.provinceId)}',
        );
      case UpdateType.destroy:
        return _simple(
          e,
          ConqueraColors.muted,
          '${_building(e.buildingId)} destroyed in ${_province(e.provinceId)}',
        );
      case UpdateType.attack:
        return _war(e);
    }
  }

  // --- Cards ---------------------------------------------------------------

  static const double _maxWidth = 440;

  Widget _frame({
    required Color color,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth, minHeight: 68),
        child: Material(
          color: color.withAlpha(22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: color),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 20,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _simple(UpdateEntry e, Color color, String text) {
    return _frame(
      color: color,
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: ConqueraText.value.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: ConqueraSpace.sm),
          Text(_time(e.at), style: ConqueraText.label),
        ],
      ),
    );
  }

  Widget _war(UpdateEntry e) {
    final mine = e.attackerId == widget.uid;
    // Green when it went well for you (you won as attacker, or held as
    // defender), red when it didn't.
    final good = e.won == mine;
    final color = good ? ConqueraColors.success : ConqueraColors.danger;
    final open = _open.contains(e.id);
    final headline = ConqueraText.value.copyWith(
      color: color,
      fontWeight: FontWeight.w600,
    );

    return _frame(
      color: color,
      onTap: () => setState(() {
        if (!_open.remove(e.id)) _open.add(e.id);
      }),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    mine
                        // You invaded {territory in its owner's color}
                        ? TextSpan(
                            style: headline,
                            children: [
                              const TextSpan(text: 'You invaded '),
                              TextSpan(
                                text: _province(e.targetId),
                                style: TextStyle(
                                  color: _playerColor(e.defenderId),
                                ),
                              ),
                            ],
                          )
                        // {Player in their color} invaded {your territory}
                        : TextSpan(
                            style: headline,
                            children: [
                              TextSpan(
                                text: _player(e.attackerId),
                                style: TextStyle(
                                  color: _playerColor(e.attackerId),
                                ),
                              ),
                              TextSpan(
                                text: ' invaded ${_province(e.targetId)}',
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm),
                Text(_time(e.at), style: ConqueraText.label),
                const SizedBox(width: ConqueraSpace.xs),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: ConqueraColors.muted,
                ),
              ],
            ),
            if (open) ..._details(e, mine),
          ],
        ),
      ),
    );
  }

  List<Widget> _details(UpdateEntry e, bool mine) {
    final bonus = e.defenseMultiplier > 1.0001
        ? '${_building(e.targetBuilding)} x${_x(e.defenseMultiplier)}'
        : null;
    final outcome = e.won
        ? '${_province(e.targetId)} was annexed'
            '${e.targetBuilding != 'none' ? ' and its ${_building(e.targetBuilding)} destroyed' : ''}.'
        : '${_province(e.targetId)} held.';

    return [
      const SizedBox(height: ConqueraSpace.md),
      // Attacker on the left, defender on the right, each in their color.
      // The divider is drawn behind the row and stretched to the row's
      // height. (IntrinsicHeight did the same, but its height guess could be
      // a pixel short of the real layout and flash an overflow error while
      // the card was expanding.)
      Stack(
        children: [
          const Positioned.fill(
            child: Align(
              child: SizedBox(
                width: 1,
                height: double.infinity,
                child: ColoredBox(color: ConqueraColors.divider),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: ConqueraSpace.md),
                  child: _side(
                    playerId: e.attackerId,
                    role: 'Attacking',
                    power: 'Attack power ${e.attackerPower.floor()}',
                    rows: e.attackers,
                    rightSide: false,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: ConqueraSpace.md),
                  child: _side(
                    playerId: e.defenderId,
                    role: 'Defending',
                    power: 'Defense power ${e.defenderPower.floor()}',
                    bonus: bonus,
                    rows: e.defenders,
                    rightSide: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: ConqueraSpace.md),
      Text(
        outcome,
        textAlign: TextAlign.center,
        style: ConqueraText.value.copyWith(
          fontWeight: FontWeight.w600,
          color: (e.won == mine) ? ConqueraColors.success : ConqueraColors.danger,
        ),
      ),
    ];
  }

  /// One side of a war: the player's name in their color, their power and
  /// their territories with troops before and after. The defending side is
  /// mirrored so the two sides face each other.
  Widget _side({
    required String? playerId,
    required String role,
    required String power,
    String? bonus,
    required List<TroopRow> rows,
    required bool rightSide,
  }) {
    final color = _playerColor(playerId);
    final align = rightSide ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final textAlign = rightSide ? TextAlign.right : TextAlign.left;

    return Column(
      crossAxisAlignment: align,
      children: [
        Text(
          _player(playerId),
          textAlign: textAlign,
          style: ConqueraText.name.copyWith(color: color),
        ),
        Text(
          role.toUpperCase(),
          style: ConqueraText.label.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: ConqueraSpace.sm),
        Text(power, textAlign: textAlign, style: ConqueraText.value),
        if (bonus != null)
          Text(
            bonus,
            textAlign: textAlign,
            style: ConqueraText.label.copyWith(fontSize: 13.5),
          ),
        const SizedBox(height: ConqueraSpace.sm),
        for (final r in rows) _troopLine(r, rightSide),
      ],
    );
  }

  Widget _troopLine(TroopRow r, bool rightSide) {
    final name = Expanded(
      child: Text(
        '${_province(r.id)}${r.isTarget ? '  (target)' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: rightSide ? TextAlign.right : TextAlign.left,
        style: ConqueraText.value,
      ),
    );
    final troops = Text(
      '${r.before.floor()} → ${r.after.floor()}',
      style: ConqueraText.value.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: ConqueraColors.muted,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: rightSide
            ? [troops, const SizedBox(width: ConqueraSpace.sm), name]
            : [name, const SizedBox(width: ConqueraSpace.sm), troops],
      ),
    );
  }

  // --- Formatting ----------------------------------------------------------

  String _x(double m) => m % 1 == 0 ? '${m.toInt()}' : m.toStringAsFixed(1);

  String _time(DateTime? at) {
    final t = (at ?? DateTime.now()).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}