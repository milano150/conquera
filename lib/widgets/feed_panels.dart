import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/game_rules.dart';
import '../models/log_entry.dart';
import '../models/player_state.dart';
import '../models/update_entry.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';

/// Sidebar previews of the History and Log screens: the latest entries as
/// small one-line cards, plus an expand button that opens the full screen.

class _FeedHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final VoidCallback onExpand;

  const _FeedHeader({
    required this.title,
    required this.onBack,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ConqueraSpace.sm,
        ConqueraSpace.sm,
        ConqueraSpace.sm,
        ConqueraSpace.xs,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 20),
            color: ConqueraColors.ink,
            tooltip: 'Back',
          ),
          Expanded(
            child: Text(title, style: ConqueraText.title.copyWith(fontSize: 22)),
          ),
          IconButton(
            onPressed: onExpand,
            icon: const Icon(Icons.open_in_full, size: 18),
            color: ConqueraColors.accent,
            tooltip: 'Expand',
          ),
        ],
      ),
    );
  }
}

/// A scrolling list fed by [stream]: oldest at the top, newest at the
/// bottom, staying glued to the bottom unless the player scrolled up.
class _Feed<T> extends StatefulWidget {
  final Stream<List<T>> stream;
  final Widget Function(T item) itemBuilder;
  final String empty;

  const _Feed({
    required this.stream,
    required this.itemBuilder,
    required this.empty,
  });

  @override
  State<_Feed<T>> createState() => _FeedState<T>();
}

class _FeedState<T> extends State<_Feed<T>> {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<List<T>>? _sub;
  List<T> _items = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (list) {
        if (!mounted) return;
        final stick = !_scroll.hasClients ||
            _scroll.position.maxScrollExtent - _scroll.offset < 100;
        setState(() {
          _items = list;
          _loaded = true;
        });
        if (stick) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scroll.hasClients) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
            }
          });
        }
      },
      onError: (Object e) => debugPrint('Feed stream error: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Text(
            widget.empty,
            textAlign: TextAlign.center,
            style: ConqueraText.label.copyWith(fontSize: 13),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        ConqueraSpace.sm,
        ConqueraSpace.xs,
        ConqueraSpace.sm,
        ConqueraSpace.sm,
      ),
      itemCount: _items.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: widget.itemBuilder(_items[i]),
      ),
    );
  }
}

Widget _miniLine(Color color, List<InlineSpan> text, DateTime? at) {
  final t = (at ?? DateTime.now()).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return DecoratedBox(
    decoration: BoxDecoration(
      color: color.withAlpha(22),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                style: ConqueraText.value.copyWith(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
                children: text,
              ),
            ),
          ),
          const SizedBox(width: ConqueraSpace.xs),
          Text(
            '${two(t.hour)}:${two(t.minute)}',
            style: ConqueraText.label.copyWith(fontSize: 11),
          ),
        ],
      ),
    ),
  );
}

/// A player's color, darkened a little so it reads on the pale cards.
Color _tint(Color? base) => base == null
    ? ConqueraColors.ink
    : Color.lerp(base, ConqueraColors.ink, 0.25)!;

Color? _hex(String? hex) {
  final v = hex == null ? null : int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Preview of the player's own History (attacks, buildings).
class HistoryPanel extends StatelessWidget {
  final String gameId;
  final String? uid;
  final FirestoreService firestore;
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, PlayerState>> players;
  final VoidCallback onBack;
  final VoidCallback onExpand;

  const HistoryPanel({
    super.key,
    required this.gameId,
    required this.uid,
    required this.firestore,
    required this.provinceNames,
    required this.players,
    required this.onBack,
    required this.onExpand,
  });

  String _province(String id) => provinceNames[id] ?? id;
  String _player(String? id) =>
      (id == null ? null : players.value[id]?.displayName) ?? 'Unknown';
  Color _color(String? id) => _tint(id == null ? null : players.value[id]?.color);
  String _building(String id) => GameRules.buildingById(id)?.name ?? id;

  Widget _item(UpdateEntry e) {
    switch (e.type) {
      case UpdateType.build:
        return _miniLine(ConqueraColors.accent, [
          TextSpan(
            text: '${_building(e.buildingId)} built in ${_province(e.provinceId)}',
          ),
        ], e.at);
      case UpdateType.destroy:
        return _miniLine(ConqueraColors.muted, [
          TextSpan(
            text:
                '${_building(e.buildingId)} destroyed in ${_province(e.provinceId)}',
          ),
        ], e.at);
      case UpdateType.missile:
        final shot = e.attackerId == uid;
        return _miniLine(
          shot ? ConqueraColors.success : ConqueraColors.danger,
          [
            TextSpan(
              text: '${shot ? 'You hit' : '${_player(e.attackerId)} hit'} '
                  '${_province(e.targetId)} with a missile',
            ),
          ],
          e.at,
        );
      case UpdateType.attack:
        final mine = e.attackerId == uid;
        final color = e.won == mine ? ConqueraColors.success : ConqueraColors.danger;
        return _miniLine(
          color,
          mine
              ? [
                  const TextSpan(text: 'You invaded '),
                  TextSpan(
                    text: _province(e.targetId),
                    style: TextStyle(color: _color(e.defenderId)),
                  ),
                ]
              : [
                  TextSpan(
                    text: _player(e.attackerId),
                    style: TextStyle(color: _color(e.attackerId)),
                  ),
                  TextSpan(text: ' invaded ${_province(e.targetId)}'),
                ],
          e.at,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = uid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FeedHeader(title: 'History', onBack: onBack, onExpand: onExpand),
        Expanded(
          child: id == null
              ? const SizedBox.shrink()
              : _Feed<UpdateEntry>(
                  stream: firestore.watchUpdates(
                    gameId: gameId,
                    uid: id,
                    limit: 40,
                  ),
                  itemBuilder: _item,
                  empty:
                      'Nothing yet. Attacks, new buildings and demolitions will show up here.',
                ),
        ),
      ],
    );
  }
}

/// Preview of the world Log.
class LogPanel extends StatelessWidget {
  final String gameId;
  final FirestoreService firestore;
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, PlayerState>> players;
  final VoidCallback onBack;
  final VoidCallback onExpand;

  const LogPanel({
    super.key,
    required this.gameId,
    required this.firestore,
    required this.provinceNames,
    required this.players,
    required this.onBack,
    required this.onExpand,
  });

  String _province(String id) => provinceNames[id] ?? id;

  String _name(String? id, String? stored) =>
      (id == null ? null : players.value[id]?.displayName) ?? stored ?? 'Unknown';

  Color _color(String? id, String? storedHex) =>
      _tint((id == null ? null : players.value[id]?.color) ?? _hex(storedHex));

  Widget _item(LogEntry e) {
    final actor = TextSpan(
      text: _name(e.actorId, e.actorName),
      style: TextStyle(color: _color(e.actorId, e.actorColor)),
    );
    switch (e.type) {
      case LogType.annex:
        return _miniLine(ConqueraColors.accent, [
          actor,
          TextSpan(text: ' annexed ${_province(e.targetId)}'),
        ], e.at);
      case LogType.attack:
        return _miniLine(
          e.won ? ConqueraColors.success : ConqueraColors.danger,
          [
            actor,
            TextSpan(
              text: ' attacked ${_province(e.targetId)}'
                  '${e.won ? ' and won' : ' and lost'}',
            ),
          ],
          e.at,
        );
      case LogType.join:
        return _miniLine(ConqueraColors.brass, [
          actor,
          const TextSpan(text: ' joined the game'),
        ], e.at);
      case LogType.eliminated:
        return _miniLine(ConqueraColors.ink, [
          TextSpan(
            text: _name(e.victimId, e.victimName),
            style: TextStyle(color: _color(e.victimId, e.victimColor)),
          ),
          const TextSpan(text: ' has been eliminated off the map by '),
          actor,
        ], e.at);
      case LogType.respawn:
        return _miniLine(ConqueraColors.muted, [
          actor,
          const TextSpan(text: ' has respawned'),
        ], e.at);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FeedHeader(title: 'Log', onBack: onBack, onExpand: onExpand),
        Expanded(
          child: _Feed<LogEntry>(
            stream: firestore.watchLog(gameId: gameId, limit: 40),
            itemBuilder: _item,
            empty: 'Nothing yet. Joins, annexations and battles will show up here.',
          ),
        ),
      ],
    );
  }
}