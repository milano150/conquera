import 'package:flutter/material.dart';

import '../state/app_settings.dart';
import '../theme/conquera_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _toggle(bool value) async {
    await AppSettings.setDarkOceans(value);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
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
              padding: const EdgeInsets.symmetric(
                horizontal: ConqueraSpace.md,
                vertical: ConqueraSpace.xs,
              ),
              decoration: BoxDecoration(
                color: ConqueraColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: ConqueraColors.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Dark oceans', style: ConqueraText.value),
                  ),
                  Switch(
                    value: AppSettings.darkOceans,
                    onChanged: _toggle,
                    activeColor: ConqueraColors.accent,
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
