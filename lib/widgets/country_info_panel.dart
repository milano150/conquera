import 'package:flutter/material.dart';

import '../theme/conquera_theme.dart';
import 'player_tag.dart';
import 'stat_block.dart';

/// Full-width panel that sits directly under the top bar while a country
/// is selected. Same surface and divider as the bar, so the two read as
/// one header. The "Manage" button on the right opens the province window.
class CountryInfoPanel extends StatelessWidget {
  final String name;

  /// Null means the country is unclaimed.
  final String? ownerName;
  final Color? ownerColor;
  final String power;
  final String building;
  final VoidCallback onClose;
  final VoidCallback onOpenDetails;

  const CountryInfoPanel({
    super.key,
    required this.name,
    required this.ownerName,
    required this.ownerColor,
    required this.power,
    required this.building,
    required this.onClose,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ConqueraColors.surface,
        border: Border(bottom: BorderSide(color: ConqueraColors.divider)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ConqueraSpace.md,
          ConqueraSpace.sm,
          ConqueraSpace.sm,
          ConqueraSpace.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ConqueraText.title,
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  tooltip: 'Close',
                  icon: const Icon(Icons.close, size: 20),
                  color: ConqueraColors.muted,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: ConqueraSpace.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: ConqueraSpace.xl,
                      runSpacing: ConqueraSpace.md,
                      children: [
                        StatBlock(
                          label: 'Owner',
                          child: PlayerTag(
                            name: ownerName ?? 'Unclaimed',
                            color: ownerColor,
                            style: ownerName == null
                                ? ConqueraText.value
                                    .copyWith(color: ConqueraColors.muted)
                                : ConqueraText.value,
                          ),
                        ),
                        StatBlock(
                          label: 'Power',
                          child: Text(power, style: ConqueraText.value),
                        ),
                        StatBlock(
                          label: 'Building',
                          child: Text(building, style: ConqueraText.value),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: ConqueraSpace.sm),
                  OutlinedButton(
                    onPressed: onOpenDetails,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Manage'),
                        SizedBox(width: 6),
                        Icon(Icons.arrow_forward, size: 16),
                      ],
                    ),
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