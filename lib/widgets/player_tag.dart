import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

/// A player's color dot followed by their name. Used everywhere a player
/// appears (top bar, country owner), so a player always looks the same.
///
/// A filled dot means a real player. A hollow ring means nobody
/// ([color] is null), e.g. an unclaimed country.
class PlayerTag extends StatelessWidget {
  final String name;
  final Color? color;
  final TextStyle? style;

  /// A bigger rounded rectangle of color instead of the small dot.
  final bool rectangle;

  const PlayerTag({
    super.key,
    required this.name,
    this.color,
    this.style,
    this.rectangle = false,
  });

  static const double _dot = 10;

  @override
  Widget build(BuildContext context) {
    final filled = color != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: rectangle ? 28 : _dot,
          height: rectangle ? 18 : _dot,
          decoration: BoxDecoration(
            color: color,
            shape: rectangle ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: rectangle ? BorderRadius.circular(5) : null,
            border: filled
                ? null
                : Border.all(color: ConqueraColors.muted, width: 1.5),
          ),
        ),
        SizedBox(width: rectangle ? 10 : ConqueraSpace.sm),
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style ?? ConqueraText.name,
          ),
        ),
      ],
    );
  }
}