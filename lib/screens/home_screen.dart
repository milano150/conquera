import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../config/saved_world.dart';
import '../models/player_state.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';
import '../widgets/fade_route.dart';
import '../widgets/light_screens_observer.dart';
import '../widgets/conquera_text_field.dart';
import 'join_screen.dart';
import 'map_screen.dart';

/// The first screen: the title and a box for the id of a world. Worlds are
/// created by hand in the database, so a world that doesn't exist is just
/// an error here.
///
/// A returning player (they already picked a name and color in that world)
/// goes straight to the map; a new one goes to [JoinScreen].
class HomeScreen extends StatefulWidget {
  /// A world to open right away (the one saved from the last session).
  final String? autoEnterWorldId;

  const HomeScreen({super.key, this.autoEnterWorldId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _worldId = TextEditingController();
  final FirestoreService _service = FirestoreService();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = widget.autoEnterWorldId;
    if (saved != null) {
      _worldId.text = saved;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enter();
      });
    }
  }

  @override
  void dispose() {
    _worldId.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    final worldId = _worldId.text.trim();
    if (worldId.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final uid = DevSession.uid;

      if (!await _service.worldExists(worldId)) {
        await SavedWorld.clear();
        if (mounted) setState(() => _error = 'No world with that id.');
        return;
      }

      final joined = await _service.playerExists(gameId: worldId, uid: uid);
      if (joined) {
        try {
          await _service.reconcileIncome(gameId: worldId, uid: uid);
        } catch (e) {
          debugPrint('Income reconcile failed: $e');
        }
      }
      if (!mounted) return;

      await Navigator.of(context).push(
        FadeRoute<void>(
          // The join screen always stays light; the map follows the setting.
          settings: joined ? null : const RouteSettings(name: kLightRouteName),
          builder: (_) => joined
              ? MapScreen(gameId: worldId)
              : JoinScreen(gameId: worldId),
        ),
      );
    } catch (e) {
      debugPrint('Entering world failed: $e');
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// BETA: pick any player that exists in the entered world and act as them
  /// from now on, then enter the world.
  Future<void> _logInAsPlayer() async {
    final worldId = _worldId.text.trim();
    if (worldId.isEmpty) {
      setState(() => _error = 'Enter a world id first.');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    List<PlayerState> players;
    try {
      if (!await _service.worldExists(worldId)) {
        if (mounted) setState(() => _error = 'No world with that id.');
        return;
      }
      players = await _service.listPlayers(gameId: worldId);
    } catch (e) {
      debugPrint('Listing players failed: $e');
      if (mounted) setState(() => _error = 'Could not reach the server.');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<_PlayerChoice>(
      context: context,
      backgroundColor: ConqueraColors.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PlayerPicker(
        players: players,
        currentUid: DevSession.isImpersonating ? DevSession.uid : null,
      ),
    );
    if (picked == null || !mounted) return;
    if (picked.uid == null) {
      DevSession.reset();
    } else {
      DevSession.actAs(picked.uid!);
    }
    await _enter();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ConqueraColors.land,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ConqueraSpace.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'conquera',
                    textAlign: TextAlign.center,
                    style: ConqueraText.title.copyWith(
                      fontSize: 36,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.xs),
                  Text(
                    'BETA',
                    textAlign: TextAlign.center,
                    style: ConqueraText.label.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.xl),
                  ConqueraTextField(
                    controller: _worldId,
                    hint: 'enter world_id',
                    autofocus: widget.autoEnterWorldId == null,
                    textInputAction: TextInputAction.go,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _enter(),
                  ),
                  const SizedBox(height: ConqueraSpace.md),
                  OutlinedButton(
                    // Stays as it is while loading; _enter ignores extra taps.
                    onPressed: _enter,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                    child: const Text('Join world'),
                  ),
                  const SizedBox(height: ConqueraSpace.sm),
                  TextButton(
                    onPressed: _busy ? null : _logInAsPlayer,
                    child: const Text('Beta: log in as any player'),
                  ),
                  const SizedBox(height: ConqueraSpace.md),
                  SizedBox(
                    height: 18,
                    child: _error == null
                        ? null
                        : Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: ConqueraText.label.copyWith(
                              color: ConqueraColors.danger,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Result of the beta picker: a player's uid, or null = use my own account.
class _PlayerChoice {
  final String? uid;
  const _PlayerChoice(this.uid);
}

/// BETA: bottom sheet listing every player of a world.
class _PlayerPicker extends StatelessWidget {
  final List<PlayerState> players;

  /// The player this device is currently acting as (null = its own account).
  final String? currentUid;

  const _PlayerPicker({required this.players, required this.currentUid});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ConqueraSpace.lg,
                0,
                ConqueraSpace.lg,
                ConqueraSpace.sm,
              ),
              child: Text('Log in as', style: ConqueraText.title),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text('My own account', style: ConqueraText.value),
                    subtitle: Text(
                      'Use this device\'s account',
                      style: ConqueraText.label,
                    ),
                    selected: currentUid == null,
                    onTap: () => Navigator.of(context).pop(const _PlayerChoice(null)),
                  ),
                  const Divider(height: 1),
                  if (players.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(ConqueraSpace.lg),
                      child: Text(
                        'No players in this world yet.',
                        style: ConqueraText.label,
                      ),
                    ),
                  for (final p in players)
                    ListTile(
                      leading: CircleAvatar(radius: 8, backgroundColor: p.color),
                      title: Text(p.displayName, style: ConqueraText.value),
                      selected: p.uid == currentUid,
                      onTap: () =>
                          Navigator.of(context).pop(_PlayerChoice(p.uid)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}