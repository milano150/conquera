import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/recent_worlds.dart';
import '../config/saved_world.dart';
import '../models/player_state.dart';
import '../services/firestore_service.dart';
import '../services/server_clock.dart';
import '../theme/conquera_theme.dart';
import '../widgets/fade_route.dart';
import '../widgets/light_screens_observer.dart';
import 'loading_screen.dart';

/// Shown to a player who is in a world that hasn't started yet (the world's
/// `startingTime` is still ahead). A centered countdown, and below it a box
/// with everyone who has joined the lobby so far. When the countdown ends the
/// world opens by itself. The start time is live: if the admin moves it, the
/// countdown follows.
class WaitingScreen extends StatefulWidget {
  final String gameId;

  const WaitingScreen({super.key, required this.gameId});

  @override
  State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
  final FirestoreService _firestore = FirestoreService();

  StreamSubscription<Map<String, dynamic>?>? _worldSub;
  StreamSubscription<Map<String, PlayerState>>? _playersSub;
  Timer? _ticker;

  DateTime? _startsAt;
  bool _worldLoaded = false;
  List<PlayerState> _players = const [];
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _worldSub = _firestore.watchWorldDoc(gameId: widget.gameId).listen(
      (world) {
        _startsAt = FirestoreService.startingTimeOf(world);
        _worldLoaded = true;
        _checkStart();
        if (mounted) setState(() {});
      },
      onError: (Object e) => debugPrint('Waiting screen world error: $e'),
    );
    _playersSub = _firestore.watchPlayers(gameId: widget.gameId).listen(
      (players) {
        final list = players.values.toList()
          ..sort((a, b) => a.displayName
              .toLowerCase()
              .compareTo(b.displayName.toLowerCase()));
        if (mounted) setState(() => _players = list);
      },
      onError: (Object e) => debugPrint('Waiting screen players error: $e'),
    );
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _checkStart();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _worldSub?.cancel();
    _playersSub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  /// Opens the world once the start time has passed (or was removed).
  void _checkStart() {
    if (_opening || !_worldLoaded || !mounted) return;
    final startsAt = _startsAt;
    if (startsAt != null && ServerClock.now().isBefore(startsAt)) return;
    _opening = true;
    Navigator.of(context).pushReplacement(
      FadeRoute<void>(
        settings: const RouteSettings(name: kLightRouteName),
        builder: (_) => LoadingScreen(gameId: widget.gameId),
      ),
    );
  }

  Future<void> _leave() async {
    // Makes sure the world is in the Play screen's list when we get back.
    if (_leaving) return;
    _leaving = true;
    await RecentWorlds.add(widget.gameId);
    await SavedWorld.clear();
    if (!mounted) return;
    RecentWorlds.openWorlds.value++;
    Navigator.of(context).pop();
  }

  bool _leaving = false;

  String _countdown(Duration left) {
    final total = left.isNegative ? 0 : left.inSeconds;
    final d = total ~/ 86400;
    final h = (total % 86400) ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return d > 0
        ? '${d}d ${two(h)}:${two(m)}:${two(s)}'
        : '${two(h)}:${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final startsAt = _startsAt;
    final left = startsAt?.difference(ServerClock.now()) ?? Duration.zero;

    return WillPopScope(
      // The system back button / gesture leaves the same way as Back.
      onWillPop: () async {
        await _leave();
        return false;
      },
      child: ColoredBox(
      color: ConqueraColors.land,
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(ConqueraSpace.md),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('The world starts in', style: ConqueraText.label),
                    const SizedBox(height: ConqueraSpace.sm),
                    Text(
                      _worldLoaded ? _countdown(left) : '--:--:--',
                      textAlign: TextAlign.center,
                      style: ConqueraText.title.copyWith(
                        fontSize: 56,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: ConqueraSpace.xs),
                    Text(widget.gameId, style: ConqueraText.label),
                    const SizedBox(height: ConqueraSpace.xl),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 320),
                      padding: const EdgeInsets.all(ConqueraSpace.md),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: ConqueraColors.divider),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'In the lobby (${_players.length})',
                            style: ConqueraText.label,
                          ),
                          const SizedBox(height: ConqueraSpace.sm),
                          Flexible(
                            child: _players.isEmpty
                                ? Text('Nobody yet', style: ConqueraText.label)
                                : ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: _players.length,
                                    itemBuilder: (_, i) {
                                      final p = _players[i];
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: p.color,
                                                borderRadius:
                                                    BorderRadius.circular(3),
                                              ),
                                            ),
                                            const SizedBox(
                                                width: ConqueraSpace.sm),
                                            Expanded(
                                              child: Text(
                                                p.displayName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: ConqueraText.name,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: ConqueraSpace.lg),
                    TextButton(onPressed: _leave, child: const Text('Back')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ));
  }
}