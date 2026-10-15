import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, on this device, the world the player was last in, so the app
/// can open it straight away on the next launch. (The player itself is tied
/// to the device by Firebase anonymous auth, which keeps its uid.)
class SavedWorld {
  const SavedWorld._();

  static const String _key = 'last_world_id';

  static Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  static Future<void> save(String worldId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, worldId);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}