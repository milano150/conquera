import 'package:firebase_auth/firebase_auth.dart';

/// BETA ONLY. Lets the join screen "log in as" a player that already exists
/// in a world, by making the whole app act with that player's uid instead
/// of this device's anonymous-auth uid.
///
/// Everything that needs "who am I" reads [DevSession.uid]. Remove this
/// file (and the beta section of the join screen) before a real release.
class DevSession {
  const DevSession._();

  static String? _override;

  /// The uid the app is acting as.
  static String get uid =>
      _override ?? FirebaseAuth.instance.currentUser!.uid;

  /// True while acting as someone other than this device's own account.
  static bool get isImpersonating => _override != null;

  static void actAs(String uid) => _override = uid;

  /// Go back to this device's own anonymous account.
  static void reset() => _override = null;
}