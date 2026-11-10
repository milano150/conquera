import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../config/recent_worlds.dart';
import '../screens/join_screen.dart';
import '../screens/map_screen.dart';
import '../widgets/fade_route.dart';
import '../widgets/light_screens_observer.dart';
import '../widgets/slide_route.dart';
import 'firestore_service.dart';

/// Opens a world by id: a returning player (they already picked a name and
/// color there) goes straight to the map, a new one to the join screen.
class WorldEntry {
  const WorldEntry._();

  /// Returns an error message to show, or null when the world was opened
  /// (and closed again).
  static Future<String?> enter(
    BuildContext context,
    FirestoreService service,
    String worldId,
  ) async {
    final id = worldId.trim();
    if (id.isEmpty) return 'Enter a world id.';

    try {
      final uid = DevSession.uid;

      if (!await service.worldExists(id)) return 'No world with that id.';

      final joined = await service.playerExists(gameId: id, uid: uid);
      if (joined) {
        try {
          await service.reconcileIncome(gameId: id, uid: uid);
        } catch (e) {
          debugPrint('Income reconcile failed: $e');
        }
        await RecentWorlds.add(id);
      }
      if (!context.mounted) return null;

      await Navigator.of(context).push(
        joined
            ? FadeRoute<void>(builder: (_) => MapScreen(gameId: id))
            : SlideRoute<void>(
                // The join screen always stays light.
                settings: const RouteSettings(name: kLightRouteName),
                builder: (_) => JoinScreen(gameId: id),
              ),
      );
      return null;
    } catch (e) {
      debugPrint('Entering world failed: $e');
      return 'Could not reach the server.';
    }
  }
}