import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/conquera_theme.dart';

/// Device-local app settings. Only the color mode for now.
class AppSettings {
  const AppSettings._();

  static const String _modeKey = 'theme_mode';

  static ConqueraMode get mode => ConqueraColors.mode;

  /// Call once before runApp.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_modeKey);
    ConqueraColors.mode = ConqueraMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => (prefs.getBool('dark_mode') ?? false)
          ? ConqueraMode.dark
          : ConqueraMode.light,
    );
  }

  static Future<void> setMode(ConqueraMode value) async {
    ConqueraColors.mode = value;
    // Colors are read from static getters, so force every widget (and
    // painter) to rebuild. State is kept, like a hot reload.
    await WidgetsBinding.instance.reassembleApplication();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, value.name);
  }
}
