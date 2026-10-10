import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../config/player_colors.dart';
import '../models/player_state.dart';
import '../models/province.dart';
import '../services/firestore_service.dart';
import '../services/svg_map_parser.dart';
import '../theme/conquera_theme.dart';
import '../widgets/blur_route.dart';
import '../widgets/conquera_text_field.dart';
import 'map_screen.dart';

/// Second screen, for a player's first visit to a world: pick a name and a
/// color. Entering creates the player (with the starting gold) and drops
/// them into the world on a random free country.
class JoinScreen extends StatefulWidget {
  final String gameId;

  const JoinScreen({super.key, required this.gameId});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final TextEditingController _name = TextEditingController();
  final FirestoreService _service = FirestoreService();
  String? _colorHex;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty && _colorHex != null && !_busy;

  /// Countries a new player can start in: every country except the tiny
  /// ones (smaller than the median), so nobody spawns on a speck.
  List<String> _spawnCandidates(List<Province> provinces) {
    final usable = provinces.where((p) => p.id != 'AQ').toList();
    if (usable.isEmpty) return const [];
    double area(Province p) => p.bounds.width * p.bounds.height;
    final areas = usable.map(area).toList()..sort();
    final median = areas[areas.length ~/ 2];
    return [
      for (final p in usable)
        if (area(p) >= median) p.id,
    ];
  }

  Future<void> _join() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final uid = DevSession.uid;
      final map = await SvgMapParser.parseAsset(MapScreen.defaultAssetPath);

      final spawn = await _service.joinWorld(
        gameId: widget.gameId,
        uid: uid,
        displayName: _name.text.trim(),
        colorHex: _colorHex!,
        spawnCandidates: _spawnCandidates(map.provinces),
      );
      if (!mounted) return;

      await Navigator.of(context).pushReplacement(
        BlurRoute<void>(
          builder: (_) => MapScreen(
            gameId: widget.gameId,
            focusProvinceId: spawn,
          ),
        ),
      );
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      debugPrint('Joining world failed: $e');
      if (mounted) setState(() => _error = 'Could not join the world.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// BETA: act as an existing player of this world and go to the map.
  Future<void> _loginAs(String uid) async {
    if (_busy) return;
    DevSession.actAs(uid);
    await Navigator.of(context).pushReplacement(
      BlurRoute<void>(builder: (_) => MapScreen(gameId: widget.gameId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                    widget.gameId,
                    textAlign: TextAlign.center,
                    style: ConqueraText.title.copyWith(fontSize: 32),
                  ),
                  const SizedBox(height: ConqueraSpace.xl),
                  ConqueraTextField(
                    controller: _name,
                    hint: 'enter name',
                    enabled: !_busy,
                    autofocus: true,
                    maxLength: 16,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _join(),
                  ),
                  const SizedBox(height: ConqueraSpace.lg),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: ConqueraSpace.sm,
                    runSpacing: ConqueraSpace.sm,
                    children: [
                      for (final hex in playerColorChoices)
                        _Swatch(
                          hex: hex,
                          selected: hex == _colorHex,
                          onTap: _busy
                              ? null
                              : () => setState(() => _colorHex = hex),
                        ),
                    ],
                  ),
                  const SizedBox(height: ConqueraSpace.lg),
                  FilledButton(
                    onPressed: _ready ? _join : null,
                    child: const Text('Enter world'),
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
                  const SizedBox(height: ConqueraSpace.lg),
                  _BetaPlayers(
                    stream: _service.watchPlayers(gameId: widget.gameId),
                    onPick: _busy ? null : _loginAs,
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

/// BETA: the players already in the lobby, tap one to log in as them.
class _BetaPlayers extends StatelessWidget {
  final Stream<Map<String, PlayerState>> stream;
  final ValueChanged<String>? onPick;

  const _BetaPlayers({required this.stream, required this.onPick});

  Color _color(String hex) {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(color: ConqueraColors.divider, height: 1),
        const SizedBox(height: ConqueraSpace.md),
        Text(
          'BETA · log in as',
          textAlign: TextAlign.center,
          style: ConqueraText.label.copyWith(letterSpacing: 0.6),
        ),
        const SizedBox(height: ConqueraSpace.sm),
        StreamBuilder<Map<String, PlayerState>>(
          stream: stream,
          builder: (context, snap) {
            final players = snap.data;
            if (players == null) {
              return const SizedBox(
                height: 24,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (players.isEmpty) {
              return Text(
                'nobody in this lobby yet',
                textAlign: TextAlign.center,
                style: ConqueraText.label,
              );
            }
            final entries = players.entries.toList()
              ..sort((a, b) => a.value.displayName
                  .toLowerCase()
                  .compareTo(b.value.displayName.toLowerCase()));
            return Wrap(
              alignment: WrapAlignment.center,
              spacing: ConqueraSpace.sm,
              runSpacing: ConqueraSpace.sm,
              children: [
                for (final e in entries)
                  ActionChip(
                    onPressed: onPick == null ? null : () => onPick!(e.key),
                    avatar: CircleAvatar(
                      radius: 6,
                      backgroundColor: _color(e.value.colorHex),
                    ),
                    label: Text(e.value.displayName, style: ConqueraText.value),
                    backgroundColor: ConqueraColors.surface,
                    side: const BorderSide(color: ConqueraColors.divider),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// A rounded square of color; the selected one gets a dark ring around it.
class _Swatch extends StatelessWidget {
  final String hex;
  final bool selected;
  final VoidCallback? onTap;

  const _Swatch({required this.hex, required this.selected, this.onTap});

  Color get _color {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected ? ConqueraColors.ink : Colors.transparent,
            width: 2,
          ),
        ),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _color,
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      ),
    );
  }
}