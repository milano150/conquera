import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../config/recent_worlds.dart';
import '../models/player_state.dart';
import '../services/firestore_service.dart';
import '../services/world_entry.dart';
import '../theme/conquera_theme.dart';
import '../widgets/conquera_text_field.dart';

/// What a world card shows, read live from the world.
class _WorldInfo {
  final bool exists;
  final bool failed;
  final PlayerState? player;

  const _WorldInfo({this.exists = true, this.failed = false, this.player});
}

/// The worlds panel that slides in from the right of the home screen: a
/// "Join with ID" button (opens a small dialog to type the id) and, under it,
/// every world this device has joined, together in one box.
class WorldsPanel extends StatefulWidget {
  final VoidCallback onBack;

  const WorldsPanel({super.key, required this.onBack});

  @override
  State<WorldsPanel> createState() => _WorldsPanelState();
}

class _WorldsPanelState extends State<WorldsPanel> {
  final FirestoreService _service = FirestoreService();

  List<String>? _ids;
  final Map<String, Future<_WorldInfo>> _info = {};
  String? _enteringId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final ids = await RecentWorlds.load();
    if (!mounted) return;
    setState(() {
      _ids = ids;
      _info
        ..clear()
        ..addEntries([for (final id in ids) MapEntry(id, _fetch(id))]);
    });
  }

  Future<_WorldInfo> _fetch(String id) async {
    try {
      if (!await _service.worldExists(id)) {
        return const _WorldInfo(exists: false);
      }
      final player = await _service.fetchPlayer(
        gameId: id,
        uid: DevSession.uid,
      );
      return _WorldInfo(player: player);
    } catch (_) {
      return const _WorldInfo(failed: true);
    }
  }

  Future<void> _open(String id) async {
    if (_enteringId != null) return;
    setState(() {
      _enteringId = id;
      _error = null;
    });
    final error = await WorldEntry.enter(context, _service, id);
    if (!mounted) return;
    setState(() {
      _enteringId = null;
      _error = error;
    });
    await _reload();
  }

  Future<void> _remove(String id) async {
    await RecentWorlds.remove(id);
    await _reload();
  }

  Future<void> _joinWithId() async {
    if (_enteringId != null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _JoinDialog(service: _service),
    );
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ConqueraColors.land,
      child: Stack(
        children: [
          SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(ConqueraSpace.lg),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Worlds',
                        textAlign: TextAlign.center,
                        style: ConqueraText.title.copyWith(
                          fontSize: 36,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: ConqueraSpace.lg),
                      OutlinedButton(
                        onPressed: _joinWithId,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                        ),
                        child: const Text('Join with ID'),
                      ),
                      const SizedBox(height: ConqueraSpace.md),
                      Flexible(child: _worldsBox()),
                      SizedBox(
                        height: 28,
                        child: _error == null
                            ? null
                            : Padding(
                                padding:
                                    const EdgeInsets.only(top: ConqueraSpace.sm),
                                child: Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: ConqueraText.label.copyWith(
                                    color: ConqueraColors.danger,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(ConqueraSpace.sm),
              child: IconButton(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 20),
                color: ConqueraColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One white box holding every world as a row.
  Widget _worldsBox() {
    final ids = _ids;
    return Material(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ConqueraColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: ids == null
          ? const SizedBox(height: 64)
          : ids.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Text(
                    'No worlds yet',
                    textAlign: TextAlign.center,
                    style: ConqueraText.label.copyWith(fontSize: 14),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: ids.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    indent: ConqueraSpace.md,
                    endIndent: ConqueraSpace.md,
                    color: ConqueraColors.divider.withAlpha(70),
                  ),
                  itemBuilder: (_, i) => _row(ids[i]),
                ),
    );
  }

  Widget _row(String id) {
    return FutureBuilder<_WorldInfo>(
      future: _info[id],
      builder: (context, snap) {
        final info = snap.data;
        final player = info?.player;
        final dim = info != null && (!info.exists || player == null);
        return InkWell(
          splashColor: ConqueraColors.ink.withAlpha(15),
          highlightColor: ConqueraColors.ink.withAlpha(8),
          onTap: info != null && !info.exists ? null : () => _open(id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ConqueraSpace.md,
              14,
              ConqueraSpace.sm,
              14,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConqueraText.name.copyWith(
                      color: dim ? ConqueraColors.muted : ConqueraColors.ink,
                    ),
                  ),
                ),
                const SizedBox(width: ConqueraSpace.sm),
                if (_enteringId == id)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: _playerTag(info, player),
                  ),
                IconButton(
                  onPressed: _enteringId == null ? () => _remove(id) : null,
                  icon: const Icon(Icons.close, size: 16),
                  color: ConqueraColors.muted,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove from list',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Player color circle + player name (or a short status).
  Widget _playerTag(_WorldInfo? info, PlayerState? player) {
    String? status;
    if (info == null) {
      status = '...';
    } else if (!info.exists) {
      status = 'gone';
    } else if (info.failed) {
      status = 'offline';
    } else if (player == null) {
      status = 'not joined';
    }
    if (status != null) {
      return Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ConqueraText.label,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: player!.color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            player.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.value,
          ),
        ),
      ],
    );
  }
}

/// The "Join with ID" dialog: type a world id and enter it.
class _JoinDialog extends StatefulWidget {
  final FirestoreService service;

  const _JoinDialog({required this.service});

  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  final TextEditingController _worldId = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _worldId.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_busy) return;
    final id = _worldId.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await WorldEntry.enter(context, widget.service, id);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
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
      if (!await widget.service.worldExists(worldId)) {
        if (mounted) setState(() => _error = 'No world with that id.');
        return;
      }
      players = await widget.service.listPlayers(gameId: worldId);
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
      backgroundColor: Colors.white,
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
    await _join();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(ConqueraSpace.lg),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: ConqueraColors.divider),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ConqueraSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Join with ID',
                textAlign: TextAlign.center,
                style: ConqueraText.title.copyWith(fontSize: 24),
              ),
              const SizedBox(height: ConqueraSpace.lg),
              ConqueraTextField(
                controller: _worldId,
                hint: 'enter world_id',
                autofocus: true,
                textInputAction: TextInputAction.go,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _join(),
              ),
              const SizedBox(height: ConqueraSpace.md),
              OutlinedButton(
                onPressed: _join,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Join'),
              ),
              const SizedBox(height: ConqueraSpace.xs),
              TextButton(
                onPressed: _busy ? null : _logInAsPlayer,
                child: const Text('Beta: log in as any player'),
              ),
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
              child: Text(
                'Log in as',
                textAlign: TextAlign.center,
                style: ConqueraText.title,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: Text(
                      'My own account',
                      textAlign: TextAlign.center,
                      style: ConqueraText.value,
                    ),
                    selected: currentUid == null,
                    onTap: () =>
                        Navigator.of(context).pop(const _PlayerChoice(null)),
                  ),
                  if (players.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(ConqueraSpace.lg),
                      child: Text(
                        'No players in this world yet.',
                        textAlign: TextAlign.center,
                        style: ConqueraText.label,
                      ),
                    ),
                  for (final p in players)
                    ListTile(
                      title: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircleAvatar(radius: 6, backgroundColor: p.color),
                          const SizedBox(width: 8),
                          Text(p.displayName, style: ConqueraText.value),
                        ],
                      ),
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