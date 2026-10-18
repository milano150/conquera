import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme/conquera_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _pick(ConqueraMode m) async {
    if (m == AppSettings.mode) return;
    await AppSettings.setMode(m);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = AppSettings.mode;
    return Scaffold(
      backgroundColor: ConqueraColors.land,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            ConqueraSpace.md,
            ConqueraSpace.sm,
            ConqueraSpace.md,
            ConqueraSpace.lg,
          ),
          children: [
            // Header
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.arrow_back_rounded, color: ConqueraColors.ink),
                  tooltip: 'Back',
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ConqueraSpace.sm,
                ConqueraSpace.xs,
                ConqueraSpace.sm,
                ConqueraSpace.lg,
              ),
              child: Text(
                'Settings',
                style: ConqueraText.title.copyWith(fontSize: 34),
              ),
            ),

            // Appearance
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ConqueraSpace.sm,
                0,
                ConqueraSpace.sm,
                ConqueraSpace.sm,
              ),
              child: Text(
                'APPEARANCE',
                style: ConqueraText.label.copyWith(
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(ConqueraSpace.sm),
              decoration: BoxDecoration(
                color: ConqueraColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: ConqueraColors.divider),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final o in _options) ...[
                    Expanded(
                      child: _ModeCard(
                        option: o,
                        selected: o.mode == current,
                        onTap: () => _pick(o.mode),
                      ),
                    ),
                    if (o != _options.last) const SizedBox(width: ConqueraSpace.sm),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Option {
  final ConqueraMode mode;
  final String label;
  final Color sea;
  final Color land;
  final Color owner;
  final bool glow;

  const _Option(this.mode, this.label, this.sea, this.land, this.owner, this.glow);
}

// Fixed colors, so each preview shows its own mode whatever is active now.
const _options = <_Option>[
  _Option(ConqueraMode.light, 'Light', Color(0xFFA7CBE3), Color(0xFFF1F6F3),
      Color(0xFFE0775A), false),
  _Option(ConqueraMode.dark, 'Dark', Color(0xFF0A0F15), Color(0xFF18212B),
      Color(0xFFA9604B), false),
  _Option(ConqueraMode.neon, 'Neon', Color(0xFF05080D), Color(0xFF0F1823),
      Color(0xFFFF6B3D), true),
];

class _ModeCard extends StatelessWidget {
  final _Option option;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = ConqueraColors.accent;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 0.78,
                child: CustomPaint(painter: _PreviewPainter(option)),
              ),
            ),
          ),
          const SizedBox(height: ConqueraSpace.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? accent : Colors.transparent,
                  border: Border.all(
                    color: selected ? accent : ConqueraColors.muted,
                    width: 1.5,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 10, color: ConqueraColors.onInk)
                    : null,
              ),
              const SizedBox(width: 6),
              Text(
                option.label,
                style: ConqueraText.value.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? ConqueraColors.ink : ConqueraColors.muted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A tiny fake map: sea, a few land blobs and one owned territory.
class _PreviewPainter extends CustomPainter {
  final _Option o;
  _PreviewPainter(this.o);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = o.sea);

    RRect blob(double l, double t, double r, double b) => RRect.fromRectAndRadius(
          Rect.fromLTRB(l * w, t * h, r * w, b * h),
          Radius.circular(w * 0.12),
        );

    final land = Paint()..color = o.land;
    canvas.drawRRect(blob(0.10, 0.12, 0.48, 0.42), land);
    canvas.drawRRect(blob(0.54, 0.20, 0.92, 0.50), land);
    canvas.drawRRect(blob(0.18, 0.58, 0.46, 0.90), land);

    final owned = blob(0.52, 0.58, 0.90, 0.88);
    if (o.glow) {
      canvas.drawRRect(
        owned,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = o.owner.withAlpha(140)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawRRect(owned, Paint()..color = o.owner.withAlpha(170));
      canvas.drawRRect(
        owned,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = o.owner,
      );
    } else {
      canvas.drawRRect(owned, Paint()..color = o.owner);
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) => old.o != o;
}
