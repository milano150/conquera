import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

/// Path of the currency icon (64px png). The folder must be listed under
/// `flutter: assets:` in pubspec.yaml.
const String goldIconAsset = 'assets/icons/gold.png';

/// The gold coin icon.
class GoldIcon extends StatelessWidget {
  final double size;

  const GoldIcon({super.key, this.size = 14});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      goldIconAsset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      // Falls back to a plain brass dot if the asset is missing.
      errorBuilder: (context, error, stackTrace) => Container(
        width: size * 0.85,
        height: size * 0.85,
        decoration: const BoxDecoration(
          color: ConqueraColors.brass,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A price: the coin followed by the amount ("[coin] 100"). With no [style]
/// the amount takes the surrounding text style (so it matches button text);
/// inside a WidgetSpan pass the style explicitly, since spans don't inherit.
class GoldAmount extends StatelessWidget {
  final num amount;
  final TextStyle? style;
  final double iconSize;

  /// Greyed out, e.g. an entry the player can't afford.
  final bool faded;

  const GoldAmount(
    this.amount, {
    super.key,
    this.style,
    this.iconSize = 14,
    this.faded = false,
  });

  @override
  Widget build(BuildContext context) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GoldIcon(size: iconSize),
        const SizedBox(width: 4),
        Text('$amount', style: style),
      ],
    );
    return faded ? Opacity(opacity: 0.4, child: row) : row;
  }
}