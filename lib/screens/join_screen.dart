import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/player_colors.dart';
import '../models/player_state.dart';
import '../models/province.dart';
import '../services/firestore_service.dart';
import '../services/spawn_candidates.dart';
import '../services/svg_map_parser.dart';
import '../theme/conquera_theme.dart';
import '../widgets/fade_route.dart';
import '../widgets/conquera_text_field.dart';
import '../widgets/player_tag.dart';
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

  /// Colors already used in this world: "#RRGGBB" (upper case) -> the player
  /// who picked it. Those swatches are locked.
  Map<String, PlayerState> _taken = const {};

  StreamSubscription<Map<String, PlayerState>>? _playersSub;

  /// The locked color whose owner is being shown above its swatch.
  String? _ownerShownFor;
  Timer? _ownerTimer;

  @override
  void initState() {
    super.initState();
    _playersSub = _service.watchPlayers(gameId: widget.gameId).listen(
      (players) {
        if (!mounted) return;
        setState(() {
          _taken = {
            for (final p in players.values) p.colorHex.toUpperCase(): p,
          };
          // Someone grabbed the color we had selected.
          if (_colorHex != null && _taken.containsKey(_colorHex)) {
            _colorHex = null;
          }
        });
      },
      onError: (Object e) => debugPrint('Watching players failed: $e'),
    );
  }

  @override
  void dispose() {
    _playersSub?.cancel();
    _ownerTimer?.cancel();
    _name.dispose();
    super.dispose();
  }

  bool get _hasChoices => _name.text.trim().isNotEmpty && _colorHex != null;

  bool get _ready => _hasChoices && !_busy;

  void _pickColor(String hex) {
    _ownerTimer?.cancel();
    if (_taken.containsKey(hex)) {
      // Locked: show who has it for a moment.
      setState(() => _ownerShownFor = hex);
      _ownerTimer = Timer(const Duration(milliseconds: 2400), () {
        if (mounted) setState(() => _ownerShownFor = null);
      });
      return;
    }
    setState(() {
      _ownerShownFor = null;
      _colorHex = hex;
    });
  }

  List<String> _spawnCandidates(List<Province> provinces) =>
      spawnCandidatesFor(provinces);

  Future<void> _join() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
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
        FadeRoute<void>(
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
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
                    'JOINING',
                    textAlign: TextAlign.center,
                    style: ConqueraText.label.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 2,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.xs),
                  Text(
                    widget.gameId,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConqueraText.title.copyWith(
                      fontSize: 32,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.xl),
                  ConqueraTextField(
                    controller: _name,
                    hint: 'enter name',
                    autofocus: true,
                    maxLength: 16,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _join(),
                  ),
                  const SizedBox(height: ConqueraSpace.lg),
                  Text(
                    'PICK A COLOR',
                    textAlign: TextAlign.center,
                    style: ConqueraText.label.copyWith(
                      fontWeight: FontWeight.w500,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.md),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: ConqueraSpace.sm,
                    runSpacing: ConqueraSpace.sm,
                    children: [
                      for (final hex in playerColorChoices)
                        _Swatch(
                          hex: hex,
                          selected: hex.toUpperCase() == _colorHex?.toUpperCase(),
                          owner: _taken[hex.toUpperCase()],
                          showOwner: _ownerShownFor == hex.toUpperCase(),
                          onTap: _busy ? null : () => _pickColor(hex.toUpperCase()),
                        ),
                    ],
                  ),
                  const SizedBox(height: ConqueraSpace.lg),
                  OutlinedButton(
                    // Stays as it is while loading; _join ignores extra taps.
                    onPressed: _hasChoices ? _join : null,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded square of color. The selected one gets a dark ring. A color
/// someone already uses is locked: a lock sits on it, it can't be selected,
/// and tapping it shows who has it, floating above the swatch.
class _Swatch extends StatelessWidget {
  final String hex;
  final bool selected;

  /// The player who has this color; null while it's free.
  final PlayerState? owner;

  /// Show [owner] floating above the swatch.
  final bool showOwner;
  final VoidCallback? onTap;

  const _Swatch({
    required this.hex,
    required this.selected,
    required this.owner,
    required this.showOwner,
    this.onTap,
  });

  static const double _size = 30;
  static const double _pad = 3;

  Color get _color {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0;
    return Color(0xFF000000 | value);
  }

  @override
  Widget build(BuildContext context) {
    final locked = owner != null;
    final color = _color;
    // Light colors get a dark lock, dark ones a white lock.
    final lockColor = color.computeLuminance() > 0.5
        ? ConqueraColors.ink
        : Colors.white;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(_pad),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected ? ConqueraColors.ink : Colors.transparent,
                width: 2,
              ),
            ),
            child: Container(
              width: _size,
              height: _size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(7),
              ),
              child: locked
                  ? Icon(Icons.lock_rounded, size: 15, color: lockColor)
                  : null,
            ),
          ),
          if (locked)
            Positioned(
              left: -80,
              right: -80,
              bottom: _size + _pad * 2 + 8,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: showOwner ? 1 : 0,
                  child: Center(child: _OwnerBubble(player: owner!)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The small label that floats above a locked color: its owner's tag.
class _OwnerBubble extends StatelessWidget {
  final PlayerState player;

  const _OwnerBubble({required this.player});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ConqueraColors.divider),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: PlayerTag(
        name: player.displayName,
        color: player.color,
        style: ConqueraText.value,
      ),
    );
  }
}