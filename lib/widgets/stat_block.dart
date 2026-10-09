import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';

/// A small caption on top of a value. Shared by the info panel and the
/// province details window so stats look the same everywhere.
class StatBlock extends StatelessWidget {
  final String label;
  final Widget child;

  const StatBlock({super.key, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ConqueraText.label),
        const SizedBox(height: ConqueraSpace.xs),
        child,
      ],
    );
  }
}