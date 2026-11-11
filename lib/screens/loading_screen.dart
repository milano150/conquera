import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../config/recent_worlds.dart';
import '../config/saved_world.dart';
import '../services/firestore_service.dart';
import '../state/map_controller.dart';
import '../theme/conquera_theme.dart';
import '../widgets/fade_route.dart';
import '../widgets/light_screens_observer.dart';
import 'home_screen.dart';
import 'map_screen.dart';

/// Shown right before a world opens. It does all the heavy work first (map
/// parsing, borders, the world's first data from Firestore), so the map
/// appears already loaded when this screen fades away.
class LoadingScreen extends StatefulWidget {
  final String gameId;

  /// A country to center the camera on (the one the player just spawned in).
  final String? focusProvinceId;

  /// True when the app starts with the saved world: first checks that the
  /// world still exists and the player is still in it. If not, this screen
  /// closes and the home screen underneath is shown.
  final bool validate;

  /// True for "Back to lobby": no world to load, it just plays and then
  /// opens the home (PLAY) screen.
  final bool toHome;

  const LoadingScreen({
    super.key,
    required this.gameId,
    this.focusProvinceId,
    this.validate = false,
  }) : toHome = false;

  const LoadingScreen.toHome({super.key})
      : gameId = '',
        focusProvinceId = null,
        validate = false,
        toHome = true;

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  /// The loader never shows for less than this, so it doesn't just flash.
  static const Duration _minTime = Duration(milliseconds: 1500);

  /// Heavy work waits for the screen's own fade-in to finish.
  static const Duration _settle = Duration(milliseconds: 750);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Network part. Returns false when the saved world can't be opened.
  Future<bool> _fetch() async {
    final service = FirestoreService();
    final id = widget.gameId;
    try {
      if (widget.validate) {
        final uid = DevSession.uid;
        if (!await service.worldExists(id)) return false;
        if (!await service.playerExists(gameId: id, uid: uid)) return false;
        try {
          await service.reconcileIncome(gameId: id, uid: uid);
        } catch (e) {
          debugPrint('Income reconcile failed: $e');
        }
      }
      // First snapshots land in Firestore's local cache, so the map's own
      // listeners get data on their first frame.
      await Future.wait<Object?>(<Future<Object?>>[
        service.watchProvinces(gameId: id).first,
        service.watchPlayers(gameId: id).first,
      ]).timeout(const Duration(seconds: 8), onTimeout: () => <Object?>[]);
    } catch (e) {
      debugPrint('Preloading world failed: $e');
      if (widget.validate) return false;
    }
    return true;
  }

  Future<void> _load() async {
    if (widget.toHome) {
      await Future<void>.delayed(_minTime);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        FadeRoute<void>(
          settings: const RouteSettings(name: kLightRouteName),
          builder: (_) => const HomeScreen(),
        ),
      );
      return;
    }

    final started = DateTime.now();
    final network = _fetch(); // runs while the screen fades in
    await Future<void>.delayed(_settle);

    await MapController.preload(MapScreen.defaultAssetPath);
    final ok = await network;

    final left = _minTime - DateTime.now().difference(started);
    if (!left.isNegative) await Future<void>.delayed(left);
    if (!mounted) return;

    if (!ok) {
      await SavedWorld.clear();
      if (mounted) Navigator.of(context).pop(); // back to the home screen
      return;
    }

    await SavedWorld.save(widget.gameId); // reopen this world next launch
    await RecentWorlds.add(widget.gameId);
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      FadeRoute<void>(
        builder: (_) => MapScreen(
          gameId: widget.gameId,
          focusProvinceId: widget.focusProvinceId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: ConqueraColors.land,
      child: Center(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_pulse.value);
            return Opacity(
              opacity: 0.75 + 0.25 * t,
              child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
            );
          },
          child: Image.asset(
            'assets/images/globe.png',
            width: 140,
            height: 140,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}