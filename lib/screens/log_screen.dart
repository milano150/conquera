import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/log_entry.dart';
import '../models/player_state.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';

/// The world's Log: one small line per public event, for every player.
/// Laid out like Updates (oldest at the top, newest at the bottom) but with
/// no details to open.
///
///  * blue: a player annexed a free territory
///  * green / red: an attack that was won / lost
///  * gold: a player joined the game
///  * dark: a player was eliminated off the map
///  * grey: a player respawned
class LogScreen extends StatefulWidget {
  final String gameId;
  final FirestoreService firestore;

  /// province id -> country name.
  final Map<String, String> provinceNames;
  final ValueListenable<Map<String, PlayerState>> players;

  const LogScreen({
    super.key,
    required this.gameId,
    required this.firestore,
    required this.provinceNames,
    required this.players,
  });

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();
  StreamSubscription<List<LogEntry>>? _sub;
  List<LogEntry> _entries = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.firestore.watchLog(gameId: widget.gameId).listen(
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
      onError: (Object e) => debugPrint('Log stream error: $e'),
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

  /// A player's name: the live one if they are still in the world, else the
  /// one stored on the event.
  String _name(String? id, String? stored) =>
      (id == null ? null : widget.players.value[id]?.displayName) ??
      stored ??
      'Unknown';

  /// A player's color, darkened a little so it reads on the pale cards.
  Color _playerColor(String? id, String? storedHex) {
    Color? base = id == null ? null : widget.players.value[id]?.color;
    if (base == null && storedHex != null) {
      final v = int.tryParse(storedHex.replaceFirst('#', ''), radix: 16);
      if (v != null) base = Color(0xFF000000 | v);
    }
    return base == null
        ? ConqueraColors.ink
        : Color.lerp(base, ConqueraColors.ink, 0.25)!;
  }

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
                  Text('Log', style: ConqueraText.title.copyWith(fontSize: 22)),
                ],
              ),
            ),
            Divider(height: 1, color: ConqueraColors.divider),
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
            'Nothing yet. Joins, annexations and battles will show up here.',
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
      itemBuilder: (context, i) {
        final e = _entries[i];
        final prev = i > 0 ? _entries[i - 1] : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (prev == null || _day(e.at) != _day(prev.at))
              _dayChip(e.at, first: prev == null),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _card(e),
            ),
          ],
        );
      },
    );
  }

  // --- Cards ---------------------------------------------------------------

  static const double _maxWidth = 440;

  Widget _card(LogEntry e) {
    final actor = TextSpan(
      text: _name(e.actorId, e.actorName),
      style: TextStyle(color: _playerColor(e.actorId, e.actorColor)),
    );
    final target = TextSpan(text: _province(e.targetId));

    switch (e.type) {
      case LogType.annex:
        return _line(e, ConqueraColors.accent, [
          actor,
          const TextSpan(text: ' annexed '),
          target,
        ]);
      case LogType.attack:
        return _line(
          e,
          e.won ? ConqueraColors.success : ConqueraColors.danger,
          [
            actor,
            const TextSpan(text: ' attacked '),
            target,
            TextSpan(text: e.won ? ' and won' : ' and lost'),
          ],
        );
      case LogType.join:
        return _line(e, ConqueraColors.brass, [
          actor,
          const TextSpan(text: ' joined the game'),
        ]);
      case LogType.eliminated:
        return _line(e, ConqueraColors.ink, [
          TextSpan(
            text: _name(e.victimId, e.victimName),
            style: TextStyle(color: _playerColor(e.victimId, e.victimColor)),
          ),
          const TextSpan(text: ' has been eliminated off the map by '),
          actor,
        ]);
      case LogType.respawn:
        return _line(e, ConqueraColors.muted, [
          actor,
          const TextSpan(text: ' has respawned'),
        ]);
    }
  }

  Widget _line(LogEntry e, Color color, List<InlineSpan> text) {
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withAlpha(22),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: ConqueraText.value.copyWith(
                        color: color,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                      children: text,
                    ),
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm),
                Text(_time(e.at), style: ConqueraText.label),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayChip(DateTime? at, {bool first = false}) {
    // Extra space above each new day separates the days from one another.
    return Padding(
      padding: EdgeInsets.only(top: first ? ConqueraSpace.sm : 32, bottom: 10),
      child: Center(
        child: Text(
          _dayLabel(at).toUpperCase(),
          style: ConqueraText.label.copyWith(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  // --- Formatting ----------------------------------------------------------

  DateTime _local(DateTime? at) => (at ?? DateTime.now()).toLocal();

  String _day(DateTime? at) {
    final t = _local(at);
    return '${t.year}-${t.month}-${t.day}';
  }

  String _dayLabel(DateTime? at) {
    final t = _local(at);
    final now = DateTime.now();
    if (_day(at) == _day(now)) return 'Today';
    if (_day(at) == _day(now.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    }
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date = '${t.day} ${months[t.month - 1]}';
    return t.year == now.year ? date : '$date ${t.year}';
  }

  String _time(DateTime? at) {
    final t = _local(at);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}