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

  const PlayerTag({super.key, required this.name, this.color, this.style});

  static const double _dot = 10;

  @override
  Widget build(BuildContext context) {
    final filled = color != null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: _dot,
          height: _dot,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: filled
                ? null
                : Border.all(color: ConqueraColors.muted, width: 1.5),
          ),
        ),
        const SizedBox(width: ConqueraSpace.sm),
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