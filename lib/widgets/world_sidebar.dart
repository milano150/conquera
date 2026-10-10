import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

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

  const WorldSidebar({
    super.key,
    required this.open,
    required this.worldId,
    required this.onClose,
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
                child: _Panel(worldId: widget.worldId),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  final String worldId;

  const _Panel({required this.worldId});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ConqueraColors.surface,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(right: BorderSide(color: ConqueraColors.divider)),
        ),
        child: SafeArea(
          child: Column(
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
                      worldId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConqueraText.title,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: ConqueraColors.divider),
              // Nothing behind these yet.
              _Item(label: 'Leaderboard', onTap: () {}),
              _Item(label: 'How to play', onTap: () {}),
              _Item(label: 'Settings', onTap: () {}),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.all(ConqueraSpace.md),
                child: FilledButton(
                  // Not functional yet.
                  onPressed: () {},
                  style: FilledButton.styleFrom(
                    backgroundColor: ConqueraColors.danger,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Leave world'),
                ),
              ),
            ],
          ),
        ),
      ),
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