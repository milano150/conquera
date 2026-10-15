import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';
import '../models/update_entry.dart';
import '../services/firestore_service.dart' show GameActionException;
import '../theme/conquera_theme.dart';
import 'player_tag.dart';

/// Full-screen "You died" screen. Put it on top of everything in a Stack
/// that fills the screen. It watches the live world data itself: when the
/// player has joined but owns no territory any more, it fades in, shows who
/// took the last one, and offers a Respawn button. It fades out again as
/// soon as the player owns a territory.
class DeathOverlay extends StatefulWidget {
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;

  /// True once the first players AND provinces data has arrived, so an empty
  /// map that simply hasn't loaded yet is never mistaken for a death.
  final ValueListenable<bool> ready;
  final String myUid;

  /// Display name of a territory (for "your last territory, X").
  final String Function(String provinceId) provinceName;

  /// The attack that took the last territory (null if unknown).
  final Future<UpdateEntry?> Function() loadLastInvasion;

  /// Puts the player back in the world. May throw [GameActionException].
  final Future<void> Function() onRespawn;

  const DeathOverlay({
    super.key,
    required this.players,
    required this.provinces,
    required this.ready,
    required this.myUid,
    required this.provinceName,
    required this.loadLastInvasion,
    required this.onRespawn,
  });

  @override
  State<DeathOverlay> createState() => _DeathOverlayState();
}

class _DeathOverlayState extends State<DeathOverlay> {
  /// The player must stay territory-less this long before the screen shows,
  /// so a half-loaded snapshot can't flash it.
  static const Duration _confirmDelay = Duration(milliseconds: 700);

  late final Listenable _merged =
      Listenable.merge([widget.players, widget.provinces, widget.ready]);

  Timer? _confirm;
  bool _dead = false; // confirmed: no territories
  bool _visible = false; // in the tree (stays true while fading out)

  UpdateEntry? _invasion;
  bool _invasionLoaded = false;

  bool _busy = false;
  String? _error;

  bool get _noTerritories {
    if (!widget.ready.value) return false;
    if (!widget.players.value.containsKey(widget.myUid)) return false;
    return !widget.provinces.value.values
        .any((s) => s.ownerId == widget.myUid);
  }

  @override
  void initState() {
    super.initState();
    _merged.addListener(_check);
    _check();
  }

  @override
  void dispose() {
    _merged.removeListener(_check);
    _confirm?.cancel();
    super.dispose();
  }

  void _check() {
    if (_noTerritories) {
      if (_dead || _confirm != null) return;
      _confirm = Timer(_confirmDelay, () {
        _confirm = null;
        if (mounted && _noTerritories) _die();
      });
    } else {
      _confirm?.cancel();
      _confirm = null;
      if (_dead) {
        setState(() {
          _dead = false;
          _busy = false;
          _error = null;
        });
      }
    }
  }

  void _die() {
    setState(() {
      _dead = true;
      _visible = true;
      _invasion = null;
      _invasionLoaded = false;
      _error = null;
    });
    _loadInvasion();
  }

  Future<void> _loadInvasion() async {
    UpdateEntry? entry;
    try {
      entry = await widget.loadLastInvasion();
    } catch (e) {
      debugPrint('Could not load the last invasion: $e');
    }
    if (!mounted) return;
    setState(() {
      _invasion = entry;
      _invasionLoaded = true;
    });
  }

  Future<void> _respawn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The screen fades out by itself once the new territory shows up.
      await widget.onRespawn();
    } on GameActionException catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      debugPrint('Respawn failed: $e');
      if (mounted) setState(() {
        _busy = false;
        _error = 'Could not respawn. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: _dead ? 1 : 0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOut,
      onEnd: () {
        if (!_dead && mounted) setState(() => _visible = false);
      },
      builder: (context, t, child) => IgnorePointer(
        ignoring: !_dead,
        child: Opacity(opacity: t, child: child),
      ),
      child: _content(),
    );
  }

  Widget _content() {
    final invasion = _invasion;
    final invader =
        invasion == null ? null : widget.players.value[invasion.attackerId];

    const white = Colors.white;
    final soft = Colors.white.withAlpha(165);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {}, // swallow taps so the map underneath stays untouched
      child: ColoredBox(
        color: ConqueraColors.ink.withAlpha(240),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Padding(
                padding: const EdgeInsets.all(ConqueraSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'You died',
                      style: ConqueraText.title.copyWith(
                        fontSize: 44,
                        color: white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: ConqueraSpace.md),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      alignment: Alignment.topCenter,
                      child: _invasionLoaded
                          ? _who(invasion, invader, soft, white)
                          : const SizedBox(width: double.infinity),
                    ),
                    const SizedBox(height: ConqueraSpace.xl),
                    SizedBox(
                      width: 200,
                      height: 48,
                      child: FilledButton(
                        onPressed: _busy ? null : _respawn,
                        style: FilledButton.styleFrom(
                          backgroundColor: white,
                          foregroundColor: ConqueraColors.ink,
                          disabledBackgroundColor: white.withAlpha(150),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: ConqueraColors.ink,
                                ),
                              )
                            : Text(
                                'Respawn',
                                style: ConqueraText.button
                                    .copyWith(color: ConqueraColors.ink),
                              ),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: ConqueraSpace.md),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: ConqueraText.label
                            .copyWith(color: const Color(0xFFFFB4B4)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "Your last territory, X, was taken by" + the invader. Falls back to a
  /// plain line when the attack can't be found.
  Widget _who(
    UpdateEntry? invasion,
    PlayerState? invader,
    Color soft,
    Color white,
  ) {
    if (invasion == null) {
      return Text(
        'You have no territories left.',
        textAlign: TextAlign.center,
        style: ConqueraText.value.copyWith(color: soft, fontSize: 15),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Your last territory, ${widget.provinceName(invasion.targetId)}, '
          'was taken by',
          textAlign: TextAlign.center,
          style: ConqueraText.value.copyWith(
            color: soft,
            fontSize: 15,
            height: 1.4,
          ),
        ),
        const SizedBox(height: ConqueraSpace.sm),
        PlayerTag(
          name: invader?.displayName ?? 'another player',
          color: invader?.color,
          square: true,
          style: ConqueraText.name.copyWith(color: white, fontSize: 20),
        ),
      ],
    );
  }
}