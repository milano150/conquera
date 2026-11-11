import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/conquera_theme.dart';

/// Device-local app settings. Only "dark oceans" for now.
class AppSettings {
  const AppSettings._();

  static const String _darkOceansKey = 'dark_oceans';

  static bool get darkOceans => ConqueraColors.darkOceans;

  /// Call once before runApp.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // The app is always in light mode now (dark / neon were removed).
    ConqueraColors.mode = ConqueraMode.light;
    ConqueraColors.darkOceans = prefs.getBool(_darkOceansKey) ?? false;
  }

  static Future<void> setDarkOceans(bool value) async {
    ConqueraColors.darkOceans = value;
    // Colors are read from static getters, so force every widget (and
    // painter) to rebuild. State is kept, like a hot reload.
    await WidgetsBinding.instance.reassembleApplication();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkOceansKey, value);
  }
}
