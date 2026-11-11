import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../config/recent_worlds.dart';
import '../screens/join_screen.dart';
import '../screens/loading_screen.dart';
import '../widgets/fade_route.dart';
import '../widgets/light_screens_observer.dart';
import '../widgets/slide_route.dart';
import 'firestore_service.dart';

/// Opens a world by id: a returning player (they already picked a name and
/// color there) goes straight to the map, a new one to the join screen.
class WorldEntry {
  const WorldEntry._();

  /// Returns an error message to show, or null when the world was opened.
  /// [onOpening] runs just before the next screen is pushed (the join dialog
  /// uses it to close itself first, so the home screen is what slides).
  static Future<String?> enter(
    BuildContext context,
    FirestoreService service,
    String worldId, {
    VoidCallback? onOpening,
  }) async {
    final id = worldId.trim();
    if (id.isEmpty) return 'Enter a world id.';

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      // Every server call gets a time limit, so a stalled connection ends
      // in an error message instead of an endless spinner.
      const limit = Duration(seconds: 15);

      debugPrint('[enter] checking world $id');
      if (!await service.worldExists(id).timeout(limit)) {
        return 'No world with that id.';
      }

      debugPrint('[enter] checking player');
      final joined =
          await service.playerExists(gameId: id, uid: uid).timeout(limit);
      if (joined) {
        try {
          debugPrint('[enter] reconciling income');
          await service.reconcileIncome(gameId: id, uid: uid).timeout(limit);
        } catch (e) {
          debugPrint('Income reconcile failed: $e');
        }
        await RecentWorlds.add(id);
      }
      if (!context.mounted) return null;
      debugPrint('[enter] opening ${joined ? 'loading screen' : 'join screen'}');

      final navigator = Navigator.of(context);
      onOpening?.call();
      await navigator.push(
        joined
            ? FadeRoute<void>(
                // The loading screen always stays light.
                settings: const RouteSettings(name: kLightRouteName),
                builder: (_) => LoadingScreen(gameId: id),
              )
            : SlideRoute<void>(
                // The join screen always stays light.
                settings: const RouteSettings(name: kLightRouteName),
                builder: (_) => JoinScreen(gameId: id),
              ),
      );
      return null;
    } on TimeoutException {
      debugPrint('Entering world timed out (see the last [enter] line above)');
      return 'The server is not responding.';
    } catch (e) {
      debugPrint('Entering world failed: $e');
      return 'Could not reach the server.';
    }
  }
}