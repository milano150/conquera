import 'package:shared_preferences/shared_preferences.dart';

/// The worlds this device has joined, most recent first, so the Play screen
/// can list them. Only the ids are stored; the player's name, color and
/// stats are read live from the world.
class RecentWorlds {
  const RecentWorlds._();

  static const String _key = 'recent_worlds';
  static const int _max = 20;

  static Future<List<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? const <String>[];
  }

  /// Puts [worldId] at the top of the list.
  static Future<void> add(String worldId) async {
    final id = worldId.trim();
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = [...(prefs.getStringList(_key) ?? const <String>[])]
      ..remove(id)
      ..insert(0, id);
    await prefs.setStringList(_key, list.take(_max).toList());
  }

  static Future<void> remove(String worldId) async {
    final prefs = await SharedPreferences.getInstance();
    final list = [...(prefs.getStringList(_key) ?? const <String>[])]
      ..remove(worldId);
    await prefs.setStringList(_key, list);
  }
}