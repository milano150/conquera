import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/saved_world.dart';
import '../services/firestore_service.dart';
import '../services/world_entry.dart';
import '../theme/conquera_theme.dart';
import 'worlds_screen.dart';

/// The first screen: the title, the version and a Play button. Play slides
/// the whole screen left to reveal the worlds panel ([WorldsPanel]) - both
/// live in this one screen, so nothing sits between them while they move.
class HomeScreen extends StatefulWidget {
  /// A world to open right away (the one saved from the last session).
  final String? autoEnterWorldId;

  /// Open with the worlds panel already showing (used by "Back to lobby").
  final bool startOnWorlds;

  const HomeScreen({
    super.key,
    this.autoEnterWorldId,
    this.startOnWorlds = false,
  });

  /// Shown under BETA.
  static const String version = '1.1';

  static final Uri _creatorUrl = Uri.parse('https://github.com/milano150');

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final TapGestureRecognizer _creatorTap = TapGestureRecognizer();

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Animation<double> _slide = CurvedAnimation(
    parent: _ctrl,
    curve: Curves.easeInOutCubic,
  );

  bool _worldsShown = false;

  @override
  void initState() {
    super.initState();
    _creatorTap.onTap = _openCreator;
    if (widget.startOnWorlds) {
      _worldsShown = true;
      _ctrl.value = 1;
    }
    final saved = widget.autoEnterWorldId;
    if (saved != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoEnter(saved));
    }
  }

  @override
  void dispose() {
    _creatorTap.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _autoEnter(String worldId) async {
    if (!mounted) return;
    final error = await WorldEntry.enter(context, FirestoreService(), worldId);
    // A world that is gone shouldn't be reopened on every launch.
    if (error != null) await SavedWorld.clear();
  }

  Future<void> _openCreator() async {
    try {
      await launchUrl(
        HomeScreen._creatorUrl,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // No browser available: nothing to do.
    }
  }

  void _showWorlds() {
    _worldsShown = true;
    _ctrl.forward();
  }

  void _hideWorlds() {
    FocusScope.of(context).unfocus();
    _worldsShown = false;
    _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      // Back closes the worlds panel first.
      onWillPop: () async {
        if (_worldsShown) {
          _hideWorlds();
          return false;
        }
        return true;
      },
      child: Scaffold(
        backgroundColor: ConqueraColors.land,
        body: AnimatedBuilder(
          animation: _slide,
          builder: (context, _) {
            final t = _slide.value;
            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: t >= 1,
                    child: FractionalTranslation(
                      translation: Offset(-t, 0),
                      child: _homeContent(),
                    ),
                  ),
                  Offstage(
                    offstage: t <= 0,
                    child: FractionalTranslation(
                      translation: Offset(1 - t, 0),
                      child: WorldsPanel(onBack: _hideWorlds),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _homeContent() {
    return ColoredBox(
      color: ConqueraColors.land,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
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
                        const SizedBox(height: ConqueraSpace.xs),
                        Text(
                          HomeScreen.version,
                          textAlign: TextAlign.center,
                          style: ConqueraText.label.copyWith(
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: ConqueraSpace.xl),
                        OutlinedButton(
                          onPressed: _showWorlds,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                          ),
                          child: const Text('Play'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: ConqueraSpace.md),
              child: Text.rich(
                TextSpan(
                  style: ConqueraText.label,
                  children: [
                    const TextSpan(text: 'created by '),
                    TextSpan(
                      text: 'Milan',
                      recognizer: _creatorTap,
                      style: ConqueraText.label.copyWith(
                        color: ConqueraColors.accent,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: ConqueraColors.accent,
                      ),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}