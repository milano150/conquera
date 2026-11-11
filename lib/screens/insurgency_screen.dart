import 'package:flutter/material.dart';

import '../models/player_state.dart';
import '../models/province.dart';
import '../models/province_state.dart';
import '../services/firestore_service.dart' show GameActionException;
import '../theme/conquera_theme.dart';

/// One territory the player may hide in.
class InsurgencyCandidate {
  final Province province;
  final ProvinceState state;
  final PlayerState? owner;

  const InsurgencyCandidate({
    required this.province,
    required this.state,
    required this.owner,
  });
}

/// "Respawn as insurgency": the three most powerful territories on the map.
/// Pick one and you are secretly respawned there. [onConfirm] does the
/// respawn; on success the screen closes itself.
class InsurgencyScreen extends StatefulWidget {
  final List<InsurgencyCandidate> candidates;
  final Future<void> Function(String provinceId) onConfirm;

  const InsurgencyScreen({
    super.key,
    required this.candidates,
    required this.onConfirm,
  });

  @override
  State<InsurgencyScreen> createState() => _InsurgencyScreenState();
}

class _InsurgencyScreenState extends State<InsurgencyScreen> {
  final PageController _page = PageController(viewportFraction: 0.86);
  String? _selected;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final id = _selected;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onConfirm(id);
      if (mounted) Navigator.of(context).pop(id);
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.candidates;
    return Scaffold(
      backgroundColor: ConqueraColors.seaPlain,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: ConqueraSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ConqueraSpace.md,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed:
                              _busy ? null : () => Navigator.of(context).pop(),
                          icon: Icon(Icons.arrow_back, color: ConqueraColors.ink),
                        ),
                        Expanded(
                          child: Text(
                            'INSURGENCY',
                            textAlign: TextAlign.center,
                            style: ConqueraText.label.copyWith(
                              color: ConqueraColors.danger,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.8,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: ConqueraSpace.lg,
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Choose where to hide',
                          textAlign: TextAlign.center,
                          style: ConqueraText.title.copyWith(fontSize: 30),
                        ),
                        const SizedBox(height: ConqueraSpace.xs),
                        Text(
                          'The most powerful territories on the map. You '
                          'respawn there in secret, and after 6 hours you '
                          'can overthrow its owner.',
                          textAlign: TextAlign.center,
                          style: ConqueraText.value.copyWith(
                            color: ConqueraColors.muted,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.md),
                  Expanded(
                    child: items.isEmpty
                        ? Center(
                            child: Text(
                              'No territory to hide in right now.',
                              style: ConqueraText.value,
                            ),
                          )
                        : PageView.builder(
                            controller: _page,
                            physics: const BouncingScrollPhysics(),
                            itemCount: items.length,
                            itemBuilder: (context, i) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ConqueraSpace.xs,
                                vertical: ConqueraSpace.xs,
                              ),
                              child: _CandidateCard(
                                rank: i + 1,
                                item: items[i],
                                selected: _selected == items[i].province.id,
                                onTap: _busy
                                    ? null
                                    : () => setState(
                                          () => _selected = items[i].province.id,
                                        ),
                              ),
                            ),
                          ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ConqueraSpace.lg,
                        ConqueraSpace.sm,
                        ConqueraSpace.lg,
                        0,
                      ),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: ConqueraText.label.copyWith(
                          color: ConqueraColors.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      ConqueraSpace.lg,
                      ConqueraSpace.md,
                      ConqueraSpace.lg,
                      0,
                    ),
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed: _selected == null || _busy ? null : _confirm,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_selected == null
                                ? 'Select a territory'
                                : 'Respawn here'),
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

class _CandidateCard extends StatelessWidget {
  final int rank;
  final InsurgencyCandidate item;
  final bool selected;
  final VoidCallback? onTap;

  const _CandidateCard({
    required this.rank,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ownerColor = item.owner?.color ?? ConqueraColors.muted;
    final outline = selected ? ConqueraColors.accent : ownerColor;
    final state = item.state;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: Color.alphaBlend(outline.withAlpha(38), ConqueraColors.land),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: outline, width: selected ? 3 : 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: ConqueraColors.sea.withAlpha(90),
                      child: CustomPaint(
                        painter: _ArtPainter(
                          item.province.path,
                          ownerColor,
                          ConqueraColors.land,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: _Tag(
                      icon: Icons.bolt,
                      text: '#$rank STRONGEST',
                      color: ownerColor,
                    ),
                  ),
                  if (selected)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: Icon(
                        Icons.check_circle,
                        color: ConqueraColors.accent,
                        size: 26,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(ConqueraSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.province.name,
                    style: ConqueraText.title.copyWith(fontSize: 22),
                  ),
                  const SizedBox(height: ConqueraSpace.xs),
                  Text.rich(
                    TextSpan(
                      style: ConqueraText.value.copyWith(fontSize: 14),
                      children: [
                        const TextSpan(text: 'Held by '),
                        TextSpan(
                          text: item.owner?.displayName ?? 'Unknown player',
                          style: TextStyle(
                            color: ownerColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.sm),
                  Row(
                    children: [
                      Icon(Icons.shield, size: 14, color: ConqueraColors.muted),
                      const SizedBox(width: 4),
                      Text('Power ${state.troops.floor()}',
                          style: ConqueraText.label),
                      const SizedBox(width: ConqueraSpace.md),
                      Icon(Icons.apartment, size: 14, color: ConqueraColors.muted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          state.buildingLabel,
                          overflow: TextOverflow.ellipsis,
                          style: ConqueraText.label,
                        ),
                      ),
                    ],
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

class _Tag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _Tag({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: ConqueraText.label.copyWith(
              color: ConqueraColors.ink,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// The territory, fitted into the card and outlined in its owner's color.
class _ArtPainter extends CustomPainter {
  final Path path;
  final Color color;
  final Color land;

  _ArtPainter(this.path, this.color, this.land);

  @override
  void paint(Canvas canvas, Size size) {
    final b = path.getBounds();
    if (b.isEmpty) return;
    const pad = 34.0;
    final sx = (size.width - pad * 2) / b.width;
    final sy = (size.height - pad * 2) / b.height;
    final scale = sx < sy ? sx : sy;
    final dx = (size.width - b.width * scale) / 2 - b.left * scale;
    final dy = (size.height - b.height * scale) / 2 - b.top * scale;
    final m = Matrix4.translationValues(dx, dy, 0) *
        Matrix4.diagonal3Values(scale, scale, 1);
    final fitted = path.transform(m.storage);

    canvas.drawPath(
      fitted.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawPath(fitted, Paint()..color = land);
    canvas.drawPath(fitted, Paint()..color = color.withAlpha(97));
    canvas.drawPath(
      fitted,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArtPainter old) =>
      old.path != path || old.color != color || old.land != land;
}
