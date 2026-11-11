import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Short sound effects from assets/sounds/<name>.mp3:
///   click    any button
///   country  selecting a country on the map
///   claim    claiming or winning a territory
///   buzz     a failed attack
///   break    a building is destroyed
///   construct a building is built
///   reinforce troops or navy are added
///
/// Every sound is loaded once at startup into a small pool of low-latency
/// players, so playing one is just "rewind and resume" (no loading on tap).
class Sfx {
  const Sfx._();

  /// Flip to false later if we add a mute option in settings.
  static bool enabled = true;

  static const _names = [
    'click',
    'country',
    'claim',
    'buzz',
    'break',
    'construct',
    'reinforce',
  ];

  /// Players per sound: lets quick repeated taps overlap.
  static const _poolSize = 3;

  static final Map<String, List<AudioPlayer>> _pools = {};
  static final Map<String, int> _next = {};
  static Future<void>? _ready;

  /// Loads every sound. Safe to call many times; it only runs once.
  static Future<void> init() => _ready ??= _init();

  static Future<void> _init() async {
    for (final name in _names) {
      final players = <AudioPlayer>[];
      for (var i = 0; i < _poolSize; i++) {
        final p = AudioPlayer();
        try {
          // Low-latency (SoundPool) is flaky on Android phones, so Android
          // uses the regular media player; other platforms keep low latency.
          await p.setPlayerMode(
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android
                ? PlayerMode.mediaPlayer
                : PlayerMode.lowLatency,
          );
          await p.setReleaseMode(ReleaseMode.stop);
          await p.setSource(AssetSource('sounds/$name.mp3'));
          players.add(p);
        } catch (e) {
          // A missing file should never crash the game.
          debugPrint('Sfx: could not load $name.mp3: $e');
          p.dispose();
        }
      }
      _pools[name] = players;
      _next[name] = 0;
    }
  }

  static Future<void> play(String name, {double volume = 0.6}) async {
    if (!enabled) return;
    final pool = _pools[name];
    if (pool == null || pool.isEmpty) return; // not loaded (yet)
    final i = _next[name] ?? 0;
    _next[name] = (i + 1) % pool.length;
    final p = pool[i];
    // Separate try blocks: Android's low-latency (SoundPool) mode can refuse
    // seek(), and that used to skip resume() so nothing ever played.
    try {
      await p.setVolume(volume);
    } catch (_) {}
    try {
      await p.seek(Duration.zero);
    } catch (_) {}
    try {
      await p.resume();
    } catch (e) {
      debugPrint('Sfx: could not play $name: $e');
    }
  }
}

/// Wrap the whole app (MaterialApp.builder) to play the click sound
/// whenever a finger lifts off a tappable button. Buttons, icon buttons,
/// switches and list tiles all show the "click" mouse cursor when enabled;
/// disabled ones don't, so they stay silent. Map taps are not buttons, so
/// they are unaffected.
class SfxClickListener extends StatefulWidget {
  final Widget child;

  const SfxClickListener({super.key, required this.child});

  @override
  State<SfxClickListener> createState() => _SfxClickListenerState();
}

class _SfxClickListenerState extends State<SfxClickListener> {
  @override
  void initState() {
    super.initState();
    Sfx.init(); // preload the sounds as the app starts
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerUp: (event) {
        final result = HitTestResult();
        WidgetsBinding.instance
            .hitTestInView(result, event.position, event.viewId);
        var clickable = false;
        var silent = false;
        for (final entry in result.path) {
          final target = entry.target;
          if (target is RenderMetaData && target.metaData == SfxSilent.tag) {
            silent = true;
          } else if (target is RenderMouseRegion &&
              target.cursor == SystemMouseCursors.click) {
            clickable = true;
          }
        }
        if (clickable && !silent) Sfx.play('click');
      },
      child: widget.child,
    );
  }
}

/// Wrap a button in this to keep it from playing the click sound, for
/// buttons that play a sound of their own (build, reinforce, destroy).
class SfxSilent extends StatelessWidget {
  static const Object tag = 'sfx_silent';

  final Widget child;

  const SfxSilent({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: tag,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}
