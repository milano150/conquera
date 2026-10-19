import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';
import '../services/firestore_service.dart';
import '../config/saved_world.dart';
import '../screens/settings_screen.dart';
import '../theme/conquera_theme.dart';
import 'feed_panels.dart';
import 'leaderboard_panel.dart';

/// Slide-in menu that covers the left of the screen while the rest of the
/// screen (the world) blurs behind it. Put it on top of everything in a
/// Stack that fills the screen, and flip [open]: it animates in and out on
/// its own, and builds nothing while fully closed.
///
/// Tapping the blurred area calls [onClose].
class WorldSidebar extends StatefulWidget {
  final bool open;

  /// Id of the current world, shown at the top.
  final String worldId;
  final VoidCallback onClose;

  /// Live world data for the leaderboard.
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;

  /// The current player, highlighted in the leaderboard.
  final String? myUid;

  /// For the History and Log previews.
  final FirestoreService firestore;

  /// province id -> country name.
  final Map<String, String> provinceNames;

  /// Opens the full History screen (the expand button of its preview).
  final VoidCallback onOpenUpdates;

  /// Opens the full Log screen (the expand button of its preview).
  final VoidCallback onOpenLog;

  /// Opens the How to play screen.
  final VoidCallback onOpenHowToPlay;

  /// Opens straight onto the Log preview instead of the menu.
  final bool startOnLog;

  const WorldSidebar({
    super.key,
    this.startOnLog = false,
    required this.open,
    required this.worldId,
    required this.onClose,
    required this.players,
    required this.provinces,
    this.myUid,
    required this.firestore,
    required this.provinceNames,
    required this.onOpenUpdates,
    required this.onOpenLog,
    required this.onOpenHowToPlay,
  });

  @override
  State<WorldSidebar> createState() => _WorldSidebarState();
}

class _WorldSidebarState extends State<WorldSidebar>
    with SingleTickerProviderStateMixin {
  static const double _maxWidth = 280;
  static const double _maxBlur = 6;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    if (widget.open) _controller.value = 1;
  }

  @override
  void didUpdateWidget(covariant WorldSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      widget.open ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isDismissed) return const SizedBox.shrink();

        final t = _curve.value;
        final width = math.min(_maxWidth, MediaQuery.sizeOf(context).width * 0.8);

        return Stack(
          children: [
            // The world, blurred and dimmed a little.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _maxBlur * t,
                    sigmaY: _maxBlur * t,
                  ),
                  child: ColoredBox(
                    color: ConqueraColors.ink.withAlpha((60 * t).round()),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: width,
              child: FractionalTranslation(
                translation: Offset(t - 1, 0),
                child: _Panel(
                  worldId: widget.worldId,
                  players: widget.players,
                  provinces: widget.provinces,
                  myUid: widget.myUid,
                  firestore: widget.firestore,
                  provinceNames: widget.provinceNames,
                  onOpenUpdates: widget.onOpenUpdates,
                  onOpenLog: widget.onOpenLog,
                  onOpenHowToPlay: widget.onOpenHowToPlay,
                  startOnLog: widget.startOnLog,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Panel extends StatefulWidget {
  final String worldId;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final String? myUid;
  final FirestoreService firestore;
  final Map<String, String> provinceNames;
  final VoidCallback onOpenUpdates;
  final VoidCallback onOpenLog;
  final VoidCallback onOpenHowToPlay;
  final bool startOnLog;

  const _Panel({
    required this.startOnLog,
    required this.worldId,
    required this.players,
    required this.provinces,
    required this.myUid,
    required this.firestore,
    required this.provinceNames,
    required this.onOpenUpdates,
    required this.onOpenLog,
    required this.onOpenHowToPlay,
  });

  @override
  State<_Panel> createState() => _PanelState();
}

enum _View { menu, leaderboard, history, log }

class _PanelState extends State<_Panel> {
  late _View _view = widget.startOnLog ? _View.log : _View.menu;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ConqueraColors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: ConqueraColors.divider)),
        ),
        child: SafeArea(
          child: _content(context),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    void toMenu() => setState(() => _view = _View.menu);
    switch (_view) {
      case _View.leaderboard:
        return LeaderboardPanel(
          players: widget.players,
          provinces: widget.provinces,
          myUid: widget.myUid,
          onBack: toMenu,
        );
      case _View.history:
        return HistoryPanel(
          gameId: widget.worldId,
          uid: widget.myUid,
          firestore: widget.firestore,
          provinceNames: widget.provinceNames,
          players: widget.players,
          onBack: toMenu,
          onExpand: widget.onOpenUpdates,
        );
      case _View.log:
        return LogPanel(
          gameId: widget.worldId,
          firestore: widget.firestore,
          provinceNames: widget.provinceNames,
          players: widget.players,
          onBack: toMenu,
          onExpand: widget.onOpenLog,
        );
      case _View.menu:
        return _menu(context);
    }
  }

  Widget _menu(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'WORLD',
                style: ConqueraText.label.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: ConqueraSpace.xs),
              Text(
                widget.worldId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ConqueraText.title,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: ConqueraColors.divider),
        _Item(
          label: 'Leaderboard',
          onTap: () => setState(() => _view = _View.leaderboard),
        ),
        _Item(
          label: 'History',
          onTap: () => setState(() => _view = _View.history),
        ),
        _Item(label: 'Log', onTap: () => setState(() => _view = _View.log)),
        _Item(label: 'How to play', onTap: widget.onOpenHowToPlay),
        _Item(
          label: 'Settings',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: OutlinedButton(
            // Back to the home screen (first route in the stack).
            onPressed: () {
              SavedWorld.clear(); // don't reopen this world on next launch
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: ConqueraColors.danger,
              side: BorderSide(color: ConqueraColors.danger),
            ),
            child: const Text('Back to lobby'),
          ),
        ),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _Item({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ConqueraSpace.md,
          vertical: 14,
        ),
        child: Text(
          label,
          style: ConqueraText.value.copyWith(fontSize: 16),
        ),
      ),
    );
  }
}